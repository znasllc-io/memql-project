#!/usr/bin/env bash
#
# scripts/release/coherence-check.sh
# ==================================
#
# The release GATE. Validates a release lockfile:
#   - both product components (dsl-bundle + client) present,
#   - every digest a real sha256:<64hex> pin (no floating tags),
#   - engineRef + registry present;
# and, with --overlay=<env>, additionally asserts that the RENDERED overlay's
# product images are all digest-pinned AND match the lockfile digests (the
# "no drift between the pinned overlay and the release" check).
#
# GENERIC / TEMPLATE-OWNED, registry-agnostic. This is what every release + every
# promote is gated on, so an incoherent set never reaches a cluster.
#
# Capability script: docs/internal/design/capability-script-contract.md
set -euo pipefail
# shellcheck source=scripts/lib/capability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/capability.sh"

cap_init "release.coherence-check" "Validate a release lockfile: product components present + digest-pinned (+ overlay match)."
cap_spec_param "lockfile" "path to the release lockfile (required)"
cap_spec_param "overlay"  "also assert this overlay's product images match the lockfile (env: staging|prod)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# lock_scalar <file> <key> -- a top-level quoted scalar (release/registry/engineRef).
function lock_scalar() { awk -v k="$2" -F'"' '$0 ~ "^" k ":" {print $2; exit}' "$1"; }

# lock_comp <file> <comp> <field> -- a component field (image|digest).
function lock_comp() {
    awk -v comp="$2" -v field="$3" '
        $0 ~ "^  " comp ":[[:space:]]*$" { inc=1; next }
        /^  [A-Za-z]/ { inc=0 }
        inc && $1 == field":" { gsub(/"/,"",$2); print $2; exit }
    ' "$1"
}

DIGEST_RE='^sha256:[0-9a-f]{64}$'

# check_overlay <env> <lockfile> -- renders the overlay and compares each product
# image's rendered digest to the lockfile. Emits COHERENCE-FAIL lines; returns 1
# on any mismatch.
function check_overlay() {
    local env="$1" lf="$2"
    local dir="$REPO_ROOT/deploy/k8s/overlays/$env" rendered rc=0
    if [ ! -d "$dir" ]; then cap_error "COHERENCE-FAIL: overlay dir not found: $dir"; return 1; fi
    if ! rendered="$(kubectl kustomize "$dir" 2>/dev/null)"; then
        cap_error "COHERENCE-FAIL: kustomize render failed: $dir"; return 1
    fi
    local comp want got
    for comp in dsl-bundle client; do
        want="$(lock_comp "$lf" "$comp" digest)"
        # Rendered line: image: <registry>/<product>-<comp>@sha256:...
        got="$(printf '%s\n' "$rendered" | grep -oE "[^ ]*-${comp}@sha256:[0-9a-f]{64}" | head -1 | sed 's/.*@//')"
        if [ -z "$got" ]; then
            cap_error "COHERENCE-FAIL: overlay $env has no digest-pinned $comp image"; rc=1; continue
        fi
        if [ "$got" != "$want" ]; then
            cap_error "COHERENCE-FAIL: overlay $env $comp digest $got != lockfile $want"; rc=1
        fi
    done
    return "$rc"
}

function main() {
    cap_handle_meta "$@"
    cap_parse_flags "$@"

    local lf overlay
    lf="$(cap_param lockfile "")"
    overlay="$(cap_param overlay "")"
    cap_require lockfile "$lf"
    [ -f "$lf" ] || cap_fail 4 "lockfile not found: $lf"

    local errs=()
    local engine_ref registry
    engine_ref="$(lock_scalar "$lf" engineRef)"
    registry="$(lock_scalar "$lf" registry)"
    [ -n "$engine_ref" ] || errs+=("missing engineRef")
    [ -n "$registry" ]   || errs+=("missing registry")

    local comp img dig
    for comp in dsl-bundle client; do
        img="$(lock_comp "$lf" "$comp" image)"
        dig="$(lock_comp "$lf" "$comp" digest)"
        [ -n "$img" ] || errs+=("$comp: missing image")
        if [[ ! "$dig" =~ $DIGEST_RE ]]; then
            errs+=("$comp: digest not a sha256:<64hex> pin -> ${dig:-<empty>}")
        fi
    done

    if [ -n "$overlay" ]; then
        check_overlay "$overlay" "$lf" || errs+=("overlay $overlay does not match the lockfile")
    fi

    if [ "${#errs[@]}" -gt 0 ]; then
        local e; for e in "${errs[@]}"; do cap_error "COHERENCE-FAIL: $e"; done
        cap_fail 5 "lockfile failed coherence: ${#errs[@]} problem(s)"
    fi

    cap_step "OK -- $lf: 2 product components digest-pinned + coherent (engine $engine_ref)"
    cap_result_set     lockfile "$lf"
    cap_result_set     engineRef "$engine_ref"
    cap_result_set_raw components 2
    if [ -n "$overlay" ]; then cap_result_set overlay "$overlay"; fi
    cap_ok
}
main "$@"
