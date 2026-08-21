#!/usr/bin/env bash
#
# scripts/release/promote.sh
# ==========================
#
# Pin the cloud overlay's product images to a validated release lockfile, by
# DIGEST COPY -- no rebuild. The overlay gets the EXACT bytes the release built,
# so a running instance differs from CI's build only by config, never by image
# content.
#
#   promote.sh --release=<id>                  # pin deploy/k8s/overlays/cloud
#   promote.sh --release=<id> --overlay=<dir>  # pin another digest-pinned overlay
#
# ONE INSTALLATION SHAPE (engine epic znasllc-io/memql#3943): there is no
# promotion between environments because there are no environments -- `local`
# and `cloud` are two deploy TARGETS of one shape, and a second environment is
# a second INSTANCE with its own ArgoCD, domain and database. So the target
# here is an OVERLAY, named the way coherence-check.sh names it, defaulting to
# `cloud` (the one cloud overlay this repo ships); a second instance that lives
# in this repo as its own overlay directory is pinned the same way, by name.
# `local` is refused (it pins by :local tag for k3d import, never by digest).
# The former --to-env flag carried the retired environment axis; it is gone,
# not aliased.
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
cap_spec_param "overlay"  "digest-pinned overlay to pin: a directory name under deploy/k8s/overlays/ (default: cloud; local is refused)"
cap_spec_param "lockfile" "explicit lockfile path (default: deploy/releases/<release>.yaml)"
cap_spec_param "dry-run"  "print the rewritten overlay to stderr; do not write (flag)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Unknown-flag allowlist, the same local guard scripts/init.sh carries: the
# vendored cap_parse_flags accepts ANY --flag (it only rejects positionals), so
# without this a retired flag such as --to-env would be silently ignored and
# the cloud overlay pinned as if nothing were wrong. Exit 2 instead. Upstream
# fix tracked in znasllc-io/memql#2508; drop this when it lands.
CAP_KNOWN_FLAGS=" release overlay lockfile dry-run help print-spec params-stdin "

# reject_unknown_flags "$@" -- exit 2 on any --flag not in CAP_KNOWN_FLAGS.
function reject_unknown_flags() {
    local a name
    for a in "$@"; do
        case "$a" in
            --*=*) name="${a%%=*}"; name="${name#--}" ;;
            --*)   name="${a#--}" ;;
            *)     cap_fail 2 "unexpected positional argument: $a" ;;
        esac
        case "$CAP_KNOWN_FLAGS" in
            *" $name "*) ;;
            *) cap_fail 2 "unknown flag: --$name (see --help; the environment axis is gone, so there is no --to-env)" ;;
        esac
    done
}

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
    reject_unknown_flags "$@"
    cap_parse_flags "$@"

    if [ -f "$REPO_ROOT/product.env" ]; then
        # shellcheck disable=SC1091
        . "$REPO_ROOT/product.env"
    fi

    local release overlay lf dry
    release="$(cap_param release "")"
    overlay="$(cap_param overlay "cloud")"
    dry="$(cap_flag dry-run)"
    cap_require release "$release"
    # The target is an overlay DIRECTORY NAME, never a path, and never `local`:
    # the local overlay pins mutable :local tags for k3d import, so there is no
    # digest to rewrite there (rewrite_one would refuse it, less clearly).
    case "$overlay" in
        local)     cap_fail 2 "--overlay=local is refused: the local overlay pins by :local tag, never by digest" ;;
        ""|*/*|.*) cap_fail 2 "--overlay must be a bare directory name under deploy/k8s/overlays/ (got '$overlay')" ;;
    esac
    [ -n "${PRODUCT:-}" ] || cap_fail 4 "PRODUCT not set -- run scripts/init.sh (product.env missing?)"

    lf="$(cap_param lockfile "$REPO_ROOT/deploy/releases/$release.yaml")"
    [ -f "$lf" ] || cap_fail 4 "lockfile not found: $lf"
    local overlay_file="$REPO_ROOT/deploy/k8s/overlays/$overlay/kustomization.yaml"
    [ -f "$overlay_file" ] || cap_fail 4 "overlay not found: $overlay_file"

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
    cp "$overlay_file" "$tmp"
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
            cap_fail 5 "overlay $overlay not rewritten as expected for component '$comp' ($counts) -- its image name block ('$key') may have drifted, or the overlay pins no such image; overlay left untouched: $overlay_file"
        fi
        mv "$next" "$tmp"; next="$(mktemp)"
        pinned="${pinned:+$pinned }$comp=$digest"
    done
    rm -f "$next"

    if [ -n "$dry" ]; then
        cap_step "dry-run: $overlay_file would be rewritten to:"
        cat "$tmp" >&2
        rm -f "$tmp"
        cap_result_set release "$release"
        cap_result_set overlay "$overlay"
        cap_result_set overlayFile "$overlay_file"
        cap_ok
    fi

    mv "$tmp" "$overlay_file"
    cap_step "pinned $overlay_file to release $release ($pinned)"

    # Re-assert: the rewritten overlay must render + match the lockfile digests.
    if ! bash "$SCRIPT_DIR/coherence-check.sh" --lockfile="$lf" --overlay="$overlay" >/dev/null; then
        cap_fail 5 "overlay $overlay did not match the lockfile after pinning -- inspect $overlay_file"
    fi

    cap_result_set     release "$release"
    cap_result_set     overlay "$overlay"
    cap_result_set     overlayFile "$overlay_file"
    cap_result_set     pinned "$pinned"
    cap_result_set_raw components "$(printf '%s\n' "$comps" | grep -c .)"
    cap_changed
    cap_ok
}
main "$@"
