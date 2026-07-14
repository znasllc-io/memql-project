#!/usr/bin/env bash
#
# client/scripts/dev/build-image.sh
# =================================
#
# Build the product SPA container image from this checkout, import it into the
# local k3d cluster, and roll the in-cluster SPA Deployment. This is the client
# half of the local stack: the root `make up` (which owns the cluster lifecycle)
# calls `make -C client image`, which runs this. After it, the SPA serves at
# https://app.$DOMAIN from INSIDE the cluster.
#
# OPERATIONAL: this file is byte-identical to the template and reads product
# identity from product.env, so `git merge template/main` never conflicts here.
# The bundle bakes the LOCAL bootstrap envelope: the bff front door + the local
# identity URL (the only two VITE_* values src/ actually reads).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${CLIENT_ROOT}/.." && pwd)"

# Product identity from the repo-root product.env (PRODUCT, DOMAIN, ...).
# shellcheck disable=SC1091
[ -f "${REPO_ROOT}/product.env" ] && . "${REPO_ROOT}/product.env"
: "${PRODUCT:?PRODUCT not set -- run scripts/init.sh (product.env missing)}"
: "${DOMAIN:?DOMAIN not set -- run scripts/init.sh (product.env missing)}"

CLUSTER="${CLUSTER:-memql}"
NAMESPACE="${NAMESPACE:-memql}"
IMAGE="${PRODUCT}-client:local"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

function info() { printf 'INFO:  %s\n' "$*" >&2; }

function resolve_packages_token() {
    # The starter shell is self-contained (public deps only), so the image
    # builds with NO token -- the Dockerfile's BuildKit secret is optional. A
    # product that wires the published @<org>/<product>-sdk needs NODE_AUTH_TOKEN
    # (read:packages for the @<org> + @znasllc-io scopes); fall back to the gh
    # CLI token when the env var is unset, but never fail the build for the
    # self-contained starter.
    if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
        NODE_AUTH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
    export NODE_AUTH_TOKEN
}

function build_image() {
    info "Building ${IMAGE} from the client checkout (baking the local envelope)..."
    local secret_arg=()
    if [ -n "${NODE_AUTH_TOKEN:-}" ]; then
        secret_arg=(--secret "id=node_auth_token,env=NODE_AUTH_TOKEN")
    fi
    docker build \
        "${secret_arg[@]}" \
        --build-arg VITE_MEMQL_HTTP_URL="https://bff.${DOMAIN}" \
        --build-arg VITE_IDENTITY_BASE_URL="https://identity.${DOMAIN}" \
        -t "${IMAGE}" "${CLIENT_ROOT}" >&2
}

function import_image() {
    info "Importing ${IMAGE} into k3d cluster '${CLUSTER}'..."
    k3d image import "${IMAGE}" -c "${CLUSTER}" >&2
}

function roll_deployment() {
    if ! kubectl get deploy "${PRODUCT}" -n "${NAMESPACE}" &>/dev/null; then
        info "Waiting for ArgoCD to create the ${PRODUCT} Deployment..."
        local waited=0
        while ! kubectl get deploy "${PRODUCT}" -n "${NAMESPACE}" &>/dev/null; do
            sleep 5; waited=$((waited + 5))
            [ "${waited}" -ge 120 ] && { info "${PRODUCT} Deployment not found after ${waited}s -- is the product Application synced? (make -C .. up)"; return 1; }
        done
    fi
    info "Rolling the ${PRODUCT} Deployment..."
    kubectl rollout restart "deploy/${PRODUCT}" -n "${NAMESPACE}" >&2
    kubectl rollout status "deploy/${PRODUCT}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}s" >&2
    info "SPA is serving: https://app.${DOMAIN}"
}

function main() {
    resolve_packages_token
    build_image
    import_image
    roll_deployment
}

main "$@"
