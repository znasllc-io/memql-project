#!/usr/bin/env bash
#
# scripts/release/coherence-check.sh
# ==================================
#
# The release GATE. Validates a release lockfile:
#   - the dsl-bundle component plus AT LEAST ONE client-surface component
#     present (client surfaces are plural -- see clients/README.md; the
#     component set is read FROM the lockfile, never hardcoded, so a product
#     with three surfaces is gated on all three),
#   - every digest a real sha256:<64hex> pin (no floating tags),
#   - engineRef + registry present;
# and, with --overlay=<dir>, additionally asserts that the RENDERED overlay's
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
cap_spec_param "overlay"  "also assert this overlay's product images match the lockfile (a digest-pinned overlay directory name under deploy/k8s/overlays/, e.g. cloud; never local)"

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

# lock_components <file> -- the component keys under `components:`, in file
# order. Read from the lockfile rather than hardcoded, so N client surfaces are
# all gated without this script (or promote.sh) knowing their names.
function lock_components() {
    awk '
        /^components:[[:space:]]*$/ { inc=1; next }
        inc && /^[A-Za-z]/          { inc=0 }
        inc && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            k=$1; sub(/:$/,"",k); print k
        }
    ' "$1"
}

# check_overlay <overlay> <lockfile> -- renders the overlay and compares each product
# image's rendered digest to the lockfile. Emits COHERENCE-FAIL lines; returns 1
# on any mismatch.
function check_overlay() {
    local overlay="$1" lf="$2"
    local dir="$REPO_ROOT/deploy/k8s/overlays/$overlay" rendered rc=0
    # kubectl is a PREREQUISITE, not a coherence failure: its absence is exit 4
    # (precondition), never exit 5 (op failed). Guard before rendering so a
    # missing tool is reported honestly instead of masquerading as a render fail.
    if ! command -v kubectl >/dev/null 2>&1; then
        cap_fail 4 "kubectl not found -- required to render + check overlay '$overlay'"
    fi
    if [ ! -d "$dir" ]; then cap_error "COHERENCE-FAIL: overlay dir not found: $dir"; return 1; fi
    # Surface kustomize's own error (do not swallow stderr): a genuine render
    # failure is exit 5, and its diagnostic is what an operator needs.
    local render_err; render_err="$(mktemp)"
    if ! rendered="$(kubectl kustomize "$dir" 2>"$render_err")"; then
        cap_error "COHERENCE-FAIL: kustomize render failed: $dir"
        [ -s "$render_err" ] && cap_error "$(cat "$render_err")"
        rm -f "$render_err"; return 1
    fi
    rm -f "$render_err"
    local comp want got img img_re
    for comp in $(lock_components "$lf"); do
        want="$(lock_comp "$lf" "$comp" digest)"
        # Match the component's FULL image ref from the lockfile, not a
        # "-<comp>@" suffix: a suffix match would let a surface named e.g.
        # "bundle" collide with "-dsl-bundle@" and compare the wrong digest.
        img="$(lock_comp "$lf" "$comp" image)"
        img_re="$(printf '%s' "$img" | sed 's/[.[\*^$()+?{|]/\\&/g')"
        got="$(printf '%s\n' "$rendered" | grep -oE "${img_re}@sha256:[0-9a-f]{64}" | head -1 | sed 's/.*@//')"
        if [ -z "$got" ]; then
            cap_error "COHERENCE-FAIL: overlay $overlay has no digest-pinned $comp image"; rc=1; continue
        fi
        if [ "$got" != "$want" ]; then
            cap_error "COHERENCE-FAIL: overlay $overlay $comp digest $got != lockfile $want"; rc=1
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

    local comps n_comps comp img dig
    comps="$(lock_components "$lf")"
    n_comps="$(printf '%s\n' "$comps" | grep -c . || true)"
    # A lockfile must carry the bundle AND at least one client surface. Without
    # this the gate would pass vacuously on a lockfile whose components block
    # failed to render (zero keys parsed = zero checks run).
    printf '%s\n' "$comps" | grep -qx 'dsl-bundle' || errs+=("missing the dsl-bundle component")
    [ "$n_comps" -ge 2 ] || errs+=("lockfile has $n_comps component(s); expected the dsl-bundle plus at least one client surface")
    for comp in $comps; do
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

    cap_step "OK -- $lf: $n_comps product components digest-pinned + coherent (engine $engine_ref)"
    cap_result_set     lockfile "$lf"
    cap_result_set     engineRef "$engine_ref"
    cap_result_set_raw components "$n_comps"
    if [ -n "$overlay" ]; then cap_result_set overlay "$overlay"; fi
    cap_ok
}
main "$@"
