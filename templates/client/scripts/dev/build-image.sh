#!/usr/bin/env bash
#
# scripts/dev/build-image.sh
# ==========================
#
# Build the LOCAL SPA container image from this checkout, import it into
# the k3d cluster, and roll the in-cluster __PRODUCT__ Deployment (owned by
# the sibling pack repo's local overlay). This is the second half of this
# repo's `make up`: after it, the SPA serves at https://app.__DOMAIN__
# from INSIDE the cluster -- nothing runs on the host and the stack
# survives the terminal session.
#
# The bundle bakes the LOCAL bootstrap envelope: same-host /memql paths
# (the front door path-routes them to bff/voice, mirroring the deployed
# public entry) + the local identity URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CLUSTER="${CLUSTER:-memql}"
NAMESPACE="${NAMESPACE:-memql}"
IMAGE="__PRODUCT__:local"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

function info() { printf 'INFO:  %s\n' "$*" >&2; }

function resolve_packages_token() {
    # The Dockerfile installs private npm packages (the product SDK) from
    # GitHub Packages and needs the node_auth_token BuildKit secret --
    # NODE_AUTH_TOKEN if set, else the gh CLI token (same fallback pattern
    # as the ArgoCD repo credential).
    if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
        NODE_AUTH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
    if [ -z "${NODE_AUTH_TOKEN:-}" ]; then
        info "ERROR: no NODE_AUTH_TOKEN and 'gh auth token' unavailable -- cannot install private npm packages."
        exit 4
    fi
    export NODE_AUTH_TOKEN
}

function build_image() {
    info "Building ${IMAGE} from the local checkout (baking the local envelope)..."
    NODE_AUTH_TOKEN="${NODE_AUTH_TOKEN}" docker build \
        --secret id=node_auth_token,env=NODE_AUTH_TOKEN \
        --build-arg VITE_MEMQL_WS_URL="wss://app.__DOMAIN__/memql/ws" \
        --build-arg VITE_MEMQL_AUDIO_WS_URL="wss://app.__DOMAIN__/memql/audio" \
        --build-arg VITE_IDENTITY_BASE_URL="https://identity.__DOMAIN__" \
        --build-arg VITE_IDENTITY_CLIENT_ID="app" \
        -t "${IMAGE}" "${REPO_ROOT}" >&2
}

function import_image() {
    info "Importing ${IMAGE} into k3d cluster '${CLUSTER}'..."
    k3d image import "${IMAGE}" -c "${CLUSTER}" >&2
}

function roll_deployment() {
    if ! kubectl get deploy __PRODUCT__ -n "${NAMESPACE}" &>/dev/null; then
        info "Waiting for ArgoCD to create the __PRODUCT__ Deployment..."
        local waited=0
        while ! kubectl get deploy __PRODUCT__ -n "${NAMESPACE}" &>/dev/null; do
            sleep 5; waited=$((waited + 5))
            [ "${waited}" -ge 120 ] && { info "__PRODUCT__ Deployment not found after ${waited}s -- is the pack overlay synced?"; return 1; }
        done
    fi
    info "Rolling the __PRODUCT__ Deployment..."
    kubectl rollout restart deploy/__PRODUCT__ -n "${NAMESPACE}" >&2
    kubectl rollout status deploy/__PRODUCT__ -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}s" >&2
    info "SPA is serving: https://app.__DOMAIN__"
}

function main() {
    resolve_packages_token
    build_image
    import_image
    roll_deployment
}

main "$@"
