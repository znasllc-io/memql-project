#!/usr/bin/env bash
#
# scripts/release/promote.sh
# ==========================
#
# Pin an environment overlay's product images to a validated release lockfile,
# by DIGEST COPY -- no rebuild. This is BOTH the initial staging pin and the
# staging->prod promote: the target env gets the EXACT bytes the release built,
# so environments differ only by config, never image content.
#
#   promote.sh --release=<id> --to-env=staging   # pin staging to a release
#   promote.sh --release=<id> --to-env=prod      # promote the same bytes to prod
#
# It re-runs the coherence gate on the lockfile first (refusing an incoherent
# set), rewrites ONLY the two product images' newName+digest in the target
# overlay's kustomization.yaml (comment-preserving; the engine bff image, pinned
# by tag, is left untouched), then re-asserts the overlay matches the lockfile.
#
# GENERIC / TEMPLATE-OWNED. Capability script:
# docs/internal/design/capability-script-contract.md
set -euo pipefail
# shellcheck source=scripts/lib/capability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/capability.sh"

cap_init "release.promote" "Pin an overlay's product images from a release lockfile (digest copy, no rebuild)."
cap_spec_param "release"  "release id -- reads deploy/releases/<release>.yaml (required)"
cap_spec_param "to-env"   "target overlay env: staging|prod (required)"
cap_spec_param "lockfile" "explicit lockfile path (default: deploy/releases/<release>.yaml)"
cap_spec_param "dry-run"  "print the rewritten overlay to stderr; do not write (flag)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# lock_scalar / lock_comp -- read the simple, fixed-shape lockfile (see
# assemble-lockfile.sh); kept standalone so promote.sh needs no shared lib.
function lock_scalar() { awk -v k="$2" -F'"' '$0 ~ "^" k ":" {print $2; exit}' "$1"; }
function lock_comp() {
    awk -v comp="$2" -v field="$3" '
        $0 ~ "^  " comp ":[[:space:]]*$" { inc=1; next }
        /^  [A-Za-z]/ { inc=0 }
        inc && $1 == field":" { gsub(/"/,"",$2); print $2; exit }
    ' "$1"
}

function main() {
    cap_handle_meta "$@"
    cap_parse_flags "$@"

    if [ -f "$REPO_ROOT/product.env" ]; then
        # shellcheck disable=SC1091
        . "$REPO_ROOT/product.env"
    fi

    local release env lf dry
    release="$(cap_param release "")"
    env="$(cap_param to-env "")"
    dry="$(cap_flag dry-run)"
    cap_require release "$release"
    cap_require to-env "$env"
    case "$env" in staging|prod) ;; *) cap_fail 2 "--to-env must be staging|prod (got '$env')" ;; esac
    [ -n "${PRODUCT:-}" ] || cap_fail 4 "PRODUCT not set -- run scripts/init.sh (product.env missing?)"

    lf="$(cap_param lockfile "$REPO_ROOT/deploy/releases/$release.yaml")"
    [ -f "$lf" ] || cap_fail 4 "lockfile not found: $lf"
    local overlay="$REPO_ROOT/deploy/k8s/overlays/$env/kustomization.yaml"
    [ -f "$overlay" ] || cap_fail 4 "overlay not found: $overlay"

    # Gate: never copy digests from an incoherent lockfile.
    if ! bash "$SCRIPT_DIR/coherence-check.sh" --lockfile="$lf" >/dev/null; then
        cap_fail 5 "refusing to promote an incoherent lockfile: $lf"
    fi

    local registry bundle_digest client_digest
    registry="$(lock_scalar "$lf" registry)"
    bundle_digest="$(lock_comp "$lf" dsl-bundle digest)"
    client_digest="$(lock_comp "$lf" client digest)"

    # kustomize `name:` keys of the two product images in the overlay: the DSL
    # bundle keeps the engine placeholder name (memql-dsl-bundle); the client is
    # <product>-client. Engine bff (memql-bff) is deliberately NOT matched.
    local bundle_name="memql-dsl-bundle" client_name="${PRODUCT}-client"
    local bundle_new="$registry/${PRODUCT}-dsl-bundle" client_new="$registry/${PRODUCT}-client"

    local tmp; tmp="$(mktemp)"
    awk -v bn="$bundle_name" -v cn="$client_name" \
        -v bnew="$bundle_new" -v bdig="$bundle_digest" \
        -v cnew="$client_new" -v cdig="$client_digest" '
        /^  - name: / {
            cur=$0; sub(/^  - name: /,"",cur); sub(/[[:space:]]+$/,"",cur)
            if (cur==bn) which="b"; else if (cur==cn) which="c"; else which=""
        }
        {
            if (which=="b" && $1=="newName:") { print "    newName: " bnew; next }
            if (which=="b" && $1=="digest:")  { print "    digest: " bdig;  next }
            if (which=="c" && $1=="newName:") { print "    newName: " cnew; next }
            if (which=="c" && $1=="digest:")  { print "    digest: " cdig;  next }
            print
        }
    ' "$overlay" > "$tmp"

    if [ -n "$dry" ]; then
        cap_step "dry-run: $overlay would be rewritten to:"
        cat "$tmp" >&2
        rm -f "$tmp"
        cap_result_set release "$release"
        cap_result_set overlay "$overlay"
        cap_ok
    fi

    mv "$tmp" "$overlay"
    cap_step "pinned $overlay to release $release (bundle=$bundle_digest client=$client_digest)"

    # Re-assert: the rewritten overlay must render + match the lockfile digests.
    if ! bash "$SCRIPT_DIR/coherence-check.sh" --lockfile="$lf" --overlay="$env" >/dev/null; then
        cap_fail 5 "overlay $env did not match the lockfile after pinning -- inspect $overlay"
    fi

    cap_result_set release "$release"
    cap_result_set overlay "$overlay"
    cap_result_set bundleDigest "$bundle_digest"
    cap_result_set clientDigest "$client_digest"
    cap_changed
    cap_ok
}
main "$@"
