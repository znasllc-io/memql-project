#!/usr/bin/env bash
#
# scripts/dev/lib.sh
# ==================
#
# Shared function library for __PRODUCT__'s dev-workflow scripts.
# Every script under scripts/dev/ sources this and uses its
# functions rather than inlining ad-hoc shell. Per the repo
# convention (see CLAUDE.md): bash scripts use function-based
# structure -- one function per responsibility, main() calls them
# in order.
#
# The local full-stack path (`make up` / `make up-refresh`, see
# scripts/dev/stack.sh) delegates the CLUSTER to the sibling
# __PRODUCT__-carrier repo's `make up` / `make up-refresh`, which drives
# the memql engine's k3d tooling with the carrier build overrides and
# registers the __PRODUCT__-local ArgoCD Application (the bff head). The
# SPA itself runs OUTSIDE the cluster as the Vite dev server on :8080,
# proxying /memql to the bff's exposed HTTP entry.

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------

# Path to the sibling carrier repo (the stack owner). Override with
# MEMQL_PACK_DIR if your checkout lives somewhere other than
# ../__PRODUCT__-carrier relative to __PRODUCT__.
readonly LIB_PACK_DIR="${MEMQL_PACK_DIR:-../__PRODUCT__-carrier}"

# The bff's entry on the local front door (traefik TLS on 443;
# bff.__DOMAIN__ resolves to 127.0.0.1). The Vite proxy target.
readonly LIB_BFF_HTTP_URL="${MEMQL_HTTP_URL:-https://bff.__DOMAIN__}"

# -----------------------------------------------------------------
# Functions
# -----------------------------------------------------------------

# check_docker: errors out with friendly guidance if the Docker
# daemon isn't running. __PRODUCT__ itself doesn't talk to Docker,
# but the stack delegation builds container images and runs k3d,
# so checking here saves the user a confusing failure mid-flow.
# Exits 0 from the calling script (NOT 1) so make doesn't flag
# this as an error.
function check_docker() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi
    cat <<'EOF'

  Docker isn't running.

  'make up' delegates to ../__PRODUCT__-carrier, which builds images
  and runs the k3d cluster, so the Docker daemon has to be up. On
  macOS: open Docker Desktop. On Linux: 'systemctl start docker' (or
  your distro's equivalent).

  Once Docker is up, re-run this command.

EOF
    exit 0
}

# require_packages_token WARNS (does not abort) if MEMQL_PACKAGES_TOKEN
# is unset. The local SPA dev server npm-installs the two private SDK
# packages (@__PRODUCT_ORG__/__PRODUCT__-sdk, @znasllc-io/memql-sdk-core)
# from GitHub Packages using this token as NODE_AUTH_TOKEN. Without it
# the cluster still comes up but `npm install` 401s.
function require_packages_token() {
    if [ -n "${MEMQL_PACKAGES_TOKEN:-}" ]; then
        return 0
    fi
    cat <<'EOF'

  WARNING: MEMQL_PACKAGES_TOKEN is not set.

  The __PRODUCT__ frontend installs its SDK packages from GitHub
  Packages using this token. The cluster will come up regardless, but
  a fresh `npm install` will 401 without it.

  Export a GitHub token with read:packages, SSO-authorized for BOTH
  the znasllc-io and __PRODUCT_ORG__ orgs (a classic PAT works, or your
  gh login if it has the scope):

      export MEMQL_PACKAGES_TOKEN=$(gh auth token)

  See docs/sdk-dependency.md. Continuing...

EOF
}

# delegate_stack runs the sibling carrier repo's make target (up or
# up-refresh) and returns its exit code. That target owns the whole
# cluster: the memql engine bring-up (with carrier-built node images
# from the pack repo's Dockerfile) plus the __PRODUCT__-local ArgoCD
# Application carrying the bff head. Bails with guidance if it fails.
function delegate_stack() {
    local target="$1"
    echo "[stack] running 'make ${target}' in ${LIB_PACK_DIR}..."
    if ! make -C "$LIB_PACK_DIR" "$target"; then
        cat <<EOF

  Stack bring-up failed. Look at the output above + try
  '(cd $LIB_PACK_DIR && make status)' to see where things stand.

EOF
        exit 1
    fi
}

# print_stack_handoff tells the user how the pieces fit after
# delegate_stack: the cluster serves the backend; the SPA is the Vite
# dev server this Makefile starts next, proxying /memql to the bff.
function print_stack_handoff() {
    cat <<EOF

  -----------------------------------------------------------
  [__PRODUCT__] Local stack is up: engine mesh + carrier nodes +
  the bff head (ArgoCD apps memql-local + __PRODUCT__-local).

  Next: the SPA image builds from this checkout and serves
  IN-CLUSTER at https://app.__DOMAIN__ (detached -- Ctrl-C is
  safe once make exits). For the attached HMR inner loop, run
  'make dev' (localhost:8080, /memql proxied to ${LIB_BFF_HTTP_URL}).

  Cluster status:   make -C ${LIB_PACK_DIR} status
  Backend logs:     kubectl logs -n memql deploy/bff -f
  -----------------------------------------------------------

EOF
}
