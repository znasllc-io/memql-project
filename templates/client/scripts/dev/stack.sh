#!/usr/bin/env bash
#
# scripts/dev/stack.sh
# ====================
#
# __PRODUCT__'s full-stack bring-up (`make up` / `make up-refresh`): boot the
# local k3d cluster -- memql engine mesh + carrier-built node images + the
# __PRODUCT__ bff head -- by delegating to the sibling __PRODUCT__-carrier
# repo's make targets, then hand off to the Vite dev server the Makefile
# starts next.
#
# Usage: stack.sh <up|up-refresh>
#
# The cluster is owned by the carrier repo (one ArgoCD Application per
# repo; see memql's docs/public/operate/downstream-stacks.md). This script
# only pre-flights Docker + the Packages token and delegates. The SPA runs
# OUTSIDE the cluster as Vite on :8080 (proxying /memql to the bff), so
# frontend HMR keeps working.
#
# Per repo convention (CLAUDE.md): function-based structure. Each
# step is its own function; main() invokes them in order.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# -----------------------------------------------------------------
# Steps
# -----------------------------------------------------------------

function preflight() {
    check_docker
    require_packages_token
}

function bring_up_stack() {
    local action="$1"
    case "$action" in
        up|up-refresh)
            delegate_stack "$action"
            ;;
        *)
            echo "usage: $0 <up|up-refresh>" >&2
            exit 1
            ;;
    esac
}

# -----------------------------------------------------------------
# Entry
# -----------------------------------------------------------------

function main() {
    local action="${1:-up}"
    preflight
    bring_up_stack "$action"
    print_stack_handoff
}

main "$@"
