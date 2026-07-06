#!/usr/bin/env bash
#
# scripts/dev/register-app.sh
# ===========================
#
# Register the __PRODUCT__-local ArgoCD Application on the shared local k3d
# cluster, then wait for the bff Deployment it owns to become Available.
#
# Runs AFTER the engine bring-up (`make -C ../memql up ...`) as the second half
# of this repo's `make up` -- one Application per repo, per the engine's
# docs/public/operate/downstream-stacks.md. The engine's up.sh is idempotent: on
# the already-running cluster it skips creation/install and only seeds the
# repository credential + applies the AppProject + Application.
#
# The repository credential (this repo may be private) comes from
# MEMQL_K3D_REPO_TOKEN; when unset we resolve it from `gh auth token`.
#
# Env overrides: ENGINE (engine checkout, default ../memql), REVISION (branch
# ArgoCD tracks, default the current branch -- PUSH IT first; ArgoCD cannot read
# local-only branches), NAMESPACE (default memql).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENGINE="${ENGINE:-${REPO_ROOT}/../memql}"
REVISION="${REVISION:-$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)}"
NAMESPACE="${NAMESPACE:-memql}"
APP_NAME="__PRODUCT__-local"
REPO_URL="https://github.com/__PRODUCT_ORG__/__PRODUCT__-carrier.git"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

function info() { printf 'INFO:  %s\n' "$*" >&2; }
function warn() { printf 'WARN:  %s\n' "$*" >&2; }

function resolve_repo_token() {
    if [ -z "${MEMQL_K3D_REPO_TOKEN:-}" ]; then
        if command -v gh &>/dev/null; then
            MEMQL_K3D_REPO_TOKEN="$(gh auth token 2>/dev/null || true)"
            export MEMQL_K3D_REPO_TOKEN
        fi
    fi
    if [ -z "${MEMQL_K3D_REPO_TOKEN:-}" ]; then
        warn "No MEMQL_K3D_REPO_TOKEN and 'gh auth token' unavailable -- ArgoCD"
        warn "cannot fetch a private repo; the ${APP_NAME} app may not sync."
    fi
}

function register_application() {
    info "Registering ${APP_NAME} (revision ${REVISION})..."
    bash "${ENGINE}/scripts/k3d/up.sh" \
        --app-name="${APP_NAME}" \
        --app-project=__PRODUCT__ \
        --project-manifest="${REPO_ROOT}/deploy/argocd/project.yaml" \
        --repo-url="${REPO_URL}" \
        --revision="${REVISION}" \
        --overlay-path=deploy/k8s/overlays/local \
        --no-secrets >&2
}

function wait_for_bff() {
    info "Waiting for ArgoCD to create the bff Deployment..."
    local waited=0
    while ! kubectl get deploy bff -n "${NAMESPACE}" &>/dev/null; do
        sleep 5; waited=$((waited + 5))
        if [ "${waited}" -ge 120 ]; then
            warn "bff Deployment not created after ${waited}s."
            warn "Is the branch '${REVISION}' pushed? Inspect:"
            warn "  kubectl get app ${APP_NAME} -n argocd"
            return 1
        fi
    done
    info "Waiting for bff to become Available (${WAIT_TIMEOUT}s)..."
    kubectl wait --for=condition=Available deploy/bff \
        -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}s" >&2
    info "bff is Available. Front door: https://bff.__DOMAIN__  (gRPC: localhost:50051 via port map)"
}

function main() {
    resolve_repo_token
    register_application
    wait_for_bff
}

main "$@"
