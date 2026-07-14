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

    # Forward only the build args the client Dockerfile actually declares. This
    # file is byte-identical across products, but each app trims the Dockerfile's
    # ARG list to the VITE_* values it reads; passing a --build-arg the Dockerfile
    # no longer declares makes docker warn ("build-arg was not consumed") and
    # couples this shared script to one product's Dockerfile. So read the declared
    # `ARG VITE_*` names and, for each, forward its value from the environment (an
    # explicit override), falling back to the local bootstrap envelope defaults
    # for the two backend URLs the starter bakes.
    local build_args=()
    local name value
    while IFS= read -r name; do
        value="${!name:-}"
        if [ -z "$value" ]; then
            case "$name" in
                VITE_MEMQL_HTTP_URL)    value="https://bff.${DOMAIN}" ;;
                VITE_IDENTITY_BASE_URL) value="https://identity.${DOMAIN}" ;;
            esac
        fi
        [ -n "$value" ] && build_args+=(--build-arg "${name}=${value}")
    done < <(awk '/^ARG[[:space:]]+VITE_/ { n=$2; sub(/=.*/, "", n); print n }' "${CLIENT_ROOT}/Dockerfile")

    docker build \
        ${secret_arg[@]+"${secret_arg[@]}"} \
        ${build_args[@]+"${build_args[@]}"} \
        -t "${IMAGE}" "${CLIENT_ROOT}" >&2
}

function import_image() {
    info "Importing ${IMAGE} into k3d cluster '${CLUSTER}'..."
    k3d image import "${IMAGE}" -c "${CLUSTER}" >&2
}

function roll_deployment() {
    # First bring-up: the Deployment does not exist yet. `make up` imports this
    # image (step 3) BEFORE it registers the product Application (step 4), which
    # is what CREATES the Deployment -- so nothing exists to roll here, and
    # ArgoCD will create it from the freshly-imported image on first sync
    # (imagePullPolicy: IfNotPresent finds the imported tag). SKIP, do not wait:
    # blocking here deadlocks `make up` (step 4 can never run until step 3
    # returns, but the Deployment only appears in step 4).
    if ! kubectl get deploy "${PRODUCT}" -n "${NAMESPACE}" &>/dev/null; then
        info "${PRODUCT} Deployment not present yet -- skipping roll; ArgoCD creates it from the imported ${IMAGE} on first sync (make up registers the product Application after this step)."
        return 0
    fi
    # Re-import (make dev, or a repeat make up): the Deployment already exists,
    # so roll it to pick up the freshly re-imported image tag.
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
