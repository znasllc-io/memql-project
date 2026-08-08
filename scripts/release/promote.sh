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
# set), rewrites ONLY the product images' newName+digest in the target overlay's
# kustomization.yaml (comment-preserving; the engine bff image, pinned by tag,
# is left untouched), then re-asserts the overlay matches the lockfile.
#
# The component set comes FROM the lockfile, never hardcoded: a product with
# three client surfaces (clients/ is plural -- see clients/README.md) has four
# product components, and each must be rewritten exactly once or the promote is
# refused with the overlay untouched.
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
function lock_components() {
    awk '
        /^components:[[:space:]]*$/ { inc=1; next }
        inc && /^[A-Za-z]/          { inc=0 }
        inc && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            k=$1; sub(/:$/,"",k); print k
        }
    ' "$1"
}

# overlay_image_key <component> -- the kustomize `- name:` key a lockfile
# component is pinned under. The DSL bundle keeps the engine's placeholder name
# (memql-dsl-bundle, set by the vendored dsl-bundle component); every client
# surface uses the <product>-<surface> rule the Deployment/Service/image all
# share. The engine bff image (memql-bff) is deliberately never matched.
function overlay_image_key() {
    case "$1" in
        dsl-bundle) printf 'memql-dsl-bundle' ;;
        *)          printf '%s-%s' "$PRODUCT" "$1" ;;
    esac
}

# rewrite_one <overlay> <image-key> <newName> <digest> <out>
# Rewrites exactly one `- name: <image-key>` block's newName + digest, printing
# the whole overlay to <out> and the substitution tally to stdout. Returns
# non-zero (leaving <out> for the caller to discard) when the block did not
# match exactly once -- a drifted overlay is never left half-rewritten on disk.
function rewrite_one() {
    local src="$1" key="$2" newname="$3" digest="$4" out="$5" counts
    counts="$(awk -v key="$key" -v nn="$newname" -v dg="$digest" '
        /^  - name: / {
            cur=$0; sub(/^  - name: /,"",cur); sub(/[[:space:]]+$/,"",cur)
            hit = (cur==key)
        }
        {
            if (hit && $1=="newName:") { print "    newName: " nn; n_name++; next }
            if (hit && $1=="digest:")  { print "    digest: " dg;  n_dig++;  next }
            print
        }
        END { printf "name=%d digest=%d\n", n_name+0, n_dig+0 > "/dev/stderr" }
    ' "$src" 2>&1 >"$out")"
    [ "$counts" = "name=1 digest=1" ] || { printf '%s' "$counts"; return 1; }
    return 0
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

    local comps; comps="$(lock_components "$lf")"
    [ -n "$comps" ] || cap_fail 5 "lockfile has no components: $lf"

    # Rewrite ONE component at a time into a scratch file, folding each result
    # back in, so the on-disk overlay is only touched after every component
    # matched exactly once. `pinned` accumulates the per-component summary.
    local tmp next comp key newname digest counts pinned=""
    tmp="$(mktemp)"; next="$(mktemp)"
    cp "$overlay" "$tmp"
    for comp in $comps; do
        key="$(overlay_image_key "$comp")"
        # newName comes from the lockfile's own image field -- the same value
        # coherence-check.sh compares the rendered overlay against, so the pin
        # and the gate can never disagree about the registry path.
        newname="$(lock_comp "$lf" "$comp" image)"
        digest="$(lock_comp "$lf" "$comp" digest)"
        if [ -z "$newname" ] || [ -z "$digest" ]; then
            rm -f "$tmp" "$next"
            cap_fail 5 "lockfile component '$comp' is missing image or digest: $lf"
        fi
        if ! counts="$(rewrite_one "$tmp" "$key" "$newname" "$digest" "$next")"; then
            rm -f "$tmp" "$next"
            cap_fail 5 "overlay $env not rewritten as expected for component '$comp' ($counts) -- its image name block ('$key') may have drifted, or the overlay pins no such image; overlay left untouched: $overlay"
        fi
        mv "$next" "$tmp"; next="$(mktemp)"
        pinned="${pinned:+$pinned }$comp=$digest"
    done
    rm -f "$next"

    if [ -n "$dry" ]; then
        cap_step "dry-run: $overlay would be rewritten to:"
        cat "$tmp" >&2
        rm -f "$tmp"
        cap_result_set release "$release"
        cap_result_set overlay "$overlay"
        cap_ok
    fi

    mv "$tmp" "$overlay"
    cap_step "pinned $overlay to release $release ($pinned)"

    # Re-assert: the rewritten overlay must render + match the lockfile digests.
    if ! bash "$SCRIPT_DIR/coherence-check.sh" --lockfile="$lf" --overlay="$env" >/dev/null; then
        cap_fail 5 "overlay $env did not match the lockfile after pinning -- inspect $overlay"
    fi

    cap_result_set     release "$release"
    cap_result_set     overlay "$overlay"
    cap_result_set     pinned "$pinned"
    cap_result_set_raw components "$(printf '%s\n' "$comps" | grep -c .)"
    cap_changed
    cap_ok
}
main "$@"
