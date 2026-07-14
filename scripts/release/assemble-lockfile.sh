#!/usr/bin/env bash
#
# scripts/release/assemble-lockfile.sh
# ====================================
#
# Assemble an IMMUTABLE release lockfile from the two product image digests that
# publish-images.yml pushed. A release = {engine ref, DSL-bundle digest, client
# digest}: the lockfile pins each product component by @sha256 so an overlay
# renders the EXACT bytes CI built.
#
# GENERIC / TEMPLATE-OWNED: reads product identity from product.env (PRODUCT,
# REGISTRY, ENGINE_REF); no product name is baked in. A second product wants
# this unchanged. Lockfiles are IMMUTABLE -- a new release gets a new file under
# deploy/releases/; never edit one in place.
#
# Capability script (non-interactive; JSON result on stdout, logs on stderr;
# honest exit codes): docs/internal/design/capability-script-contract.md
set -euo pipefail
# shellcheck source=scripts/lib/capability.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/capability.sh"

cap_init "release.assemble-lockfile" "Write deploy/releases/<release>.yaml pinning the product images by digest."
cap_spec_param "release"       "release id / immutable tag (required)"
cap_spec_param "bundle-digest" "sha256:<64hex> digest of the DSL-bundle image (required)"
cap_spec_param "client-digest" "sha256:<64hex> digest of the client SPA image (required)"
cap_spec_param "engine-ref"    "engine ref this release ships against (default: ENGINE_REF from product.env)"
cap_spec_param "registry"      "registry host/path (default: REGISTRY from product.env)"
cap_spec_param "out"           "output path (default: deploy/releases/<release>.yaml)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

function valid_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

function main() {
    cap_handle_meta "$@"
    cap_parse_flags "$@"

    # product.env feeds the defaults (env-as-default per the capability contract).
    if [ -f "$REPO_ROOT/product.env" ]; then
        # shellcheck disable=SC1091
        . "$REPO_ROOT/product.env"
    fi

    local release bundle client engine_ref registry out
    release="$(cap_param release "")"
    bundle="$(cap_param bundle-digest "")"
    client="$(cap_param client-digest "")"
    engine_ref="$(cap_param engine-ref "${ENGINE_REF:-}")"
    registry="$(cap_param registry "${REGISTRY:-}")"

    cap_require release "$release"
    cap_require bundle-digest "$bundle"
    cap_require client-digest "$client"
    [ -n "${PRODUCT:-}" ] || cap_fail 4 "PRODUCT not set -- run scripts/init.sh (product.env missing?)"
    [ -n "$registry" ]    || cap_fail 4 "no registry -- set REGISTRY in product.env or pass --registry"
    valid_digest "$bundle" || cap_fail 2 "--bundle-digest is not a sha256:<64hex> pin: $bundle"
    valid_digest "$client" || cap_fail 2 "--client-digest is not a sha256:<64hex> pin: $client"

    out="$(cap_param out "$REPO_ROOT/deploy/releases/$release.yaml")"
    mkdir -p "$(dirname "$out")"

    {
        printf '# %s release lockfile -- assembled by scripts/release/assemble-lockfile.sh.\n' "$PRODUCT"
        printf '# Immutable: a new release gets a new file; never edit in place.\n'
        printf 'release: "%s"\n' "$release"
        printf 'registry: "%s"\n' "$registry"
        printf 'engineRef: "%s"\n' "$engine_ref"
        printf 'components:\n'
        printf '  dsl-bundle:\n'
        printf '    image: "%s/%s-dsl-bundle"\n' "$registry" "$PRODUCT"
        printf '    digest: "%s"\n' "$bundle"
        printf '  client:\n'
        printf '    image: "%s/%s-client"\n' "$registry" "$PRODUCT"
        printf '    digest: "%s"\n' "$client"
    } > "$out"
    cap_step "wrote $out"

    # Self-validate: the assembled lockfile must pass the coherence gate.
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/coherence-check.sh" --lockfile="$out" >/dev/null; then
        cap_fail 5 "assembled lockfile failed the coherence gate: $out"
    fi

    cap_result_set    release "$release"
    cap_result_set    lockfile "$out"
    cap_result_set    bundleDigest "$bundle"
    cap_result_set    clientDigest "$client"
    cap_changed
    cap_ok
}
main "$@"
