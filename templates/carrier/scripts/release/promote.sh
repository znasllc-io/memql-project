#!/usr/bin/env bash
#
# scripts/release/promote.sh
# ==========================
#
# Promote a validated release to an environment overlay by DIGEST COPY -- no
# rebuild (deployment-v2 Phase 4, znasllc-io/memql#702). Reads a release
# lockfile (releases/<version>.yaml) and writes the target env overlay's
# images: block from its digests, so prod runs the EXACT bytes staging
# validated. environments differ only by config, never by image content.
#
# This is how staging->prod cutover works: promote.sh --version X --env prod
# updates deploy/k8s/overlays/prod, you PR it, and Argo CD reconciles prod.
#
# Refuses to promote an incoherent lockfile (runs coherence-check.sh first).
#
# Usage: promote.sh --version=X.Y.Z --env=prod [--dry-run]
#
# Function-based per the Skills+Scripts convention (CLAUDE.md). set -uo pipefail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACR="${ACR_LOGIN_SERVER:-acrmemql.azurecr.io}"

function info() { echo "INFO: $*"; }
function plan() { echo "  [plan] $*"; }

function parse_arguments() {
    VERSION=""; ENV=""; DRY_RUN=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version=*) VERSION="${1#*=}"; shift ;;
            --env=*)     ENV="${1#*=}"; shift ;;
            --dry-run)   DRY_RUN=true; shift ;;
            --help) echo "usage: $0 --version=X.Y.Z --env=prod [--dry-run]"; exit 0 ;;
            *) echo "ERROR: unknown option: $1"; exit 2 ;;
        esac
    done
    [ -z "$VERSION" ] && { echo "ERROR: --version required"; exit 2; }
    [ -z "$ENV" ] && { echo "ERROR: --env required"; exit 2; }
    LOCKFILE="$REPO_ROOT/releases/$VERSION.yaml"
    OVERLAY="$REPO_ROOT/deploy/k8s/overlays/$ENV"
}

function validate_inputs() {
    [ -f "$LOCKFILE" ] || { echo "ERROR: no lockfile $LOCKFILE"; exit 1; }
    [ -d "$OVERLAY" ] || { echo "ERROR: no overlay dir $OVERLAY"; exit 1; }
    info "validating lockfile coherence before promotion..."
    bash "$SCRIPT_DIR/coherence-check.sh" "$LOCKFILE" || {
        echo "ERROR: refusing to promote an incoherent lockfile"; exit 1; }

    # Connection-headroom gate (memql#1820, from the #1817 53300 spike): block a
    # promotion whose projected Sigma(replicas x MAX_OPEN_CONNS) + surge + blue-
    # green overlap would exceed the target instance's connection budget.
    # ENFORCED when the operator declares the instance budget (MAX_CONNECTIONS);
    # advisory otherwise (we can't know the budget without it).
    #
    # DECOUPLING P3: conn-headroom-check.sh is an ENGINE-GENERIC capability
    # backend and STAYS in the engine repo (it is NOT copied into this pack).
    # So the gate is OPTIONAL-IF-PRESENT here: when the script is absent from
    # this checkout, skip it with a warning rather than fail. To enforce the
    # headroom gate from this repo, run promote.sh from a workspace where the
    # engine's scripts/deploy/conn-headroom-check.sh is reachable (e.g. a
    # sibling engine checkout symlinked/copied in), or invoke the engine's
    # `make conn-headroom-check` separately before promoting.
    local headroom="$REPO_ROOT/scripts/deploy/conn-headroom-check.sh"
    if [ ! -f "$headroom" ]; then
        info "WARNING: conn-headroom-check.sh not present in this checkout (stays engine-side, decoupling P3); skipping the connection-headroom gate."
    elif [ -n "${MAX_CONNECTIONS:-}" ]; then
        info "checking connection headroom (budget MAX_CONNECTIONS=$MAX_CONNECTIONS)..."
        bash "$headroom" || {
            echo "ERROR: refusing to promote -- projected DB connections exceed the instance budget (SQLSTATE 53300 risk). Right-size MAX_OPEN_CONNS / replicas / surge, add a pooler, or raise the instance max_connections."; exit 1; }
    else
        info "connection-headroom check (advisory -- set MAX_CONNECTIONS for the target instance to enforce):"
        bash "$headroom" || true
    fi
}

# Render the images: block for the overlay kustomization from the lockfile.
# Component name -> image repo (the ACR image name) is fixed per the 8 artifacts.
function render_images_block() {
    ACR="$ACR" python3 - "$LOCKFILE" <<'PY'
import os, sys, yaml
acr = os.environ["ACR"]
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
comps = doc["components"]
# component name == ACR image name for every release component.
order = ["memql-identity","memql-bff-__PRODUCT__","memql-cognition","memql-voice",
         "memql-mcp","memql-agent","memql-planner","memql-workbench","__PRODUCT__"]
print("images:")
for name in order:
    print(f"  - name: {acr}/{name}")
    print(f"    digest: {comps[name]['digest']}")
PY
}

# DECOUPLING P3 CAVEAT -- write_overlay() rewrites the ENTIRE overlay
# kustomization from this fixed template (`resources: - ../../base` + a bare
# images: block). In THIS pack the staging/prod overlays are NOT `../../base`
# overlays: they compose the engine base via a REMOTE kustomize base URL and
# add product resources + the livekit NODE_IP patch + the identity-product-
# config patch. Running promote.sh --env here as-is would CLOBBER all of that
# (drop the remote base, the patches, and the commented product-resource
# lines). This mirrors the pre-existing engine limitation the staging overlay
# already documents ("not promote.sh, which clobbers the livekit/sip/redis
# pins + the NODE_IP patch"). The cutover runbook must either (a) hand-pin
# digests in the pack overlays' images: block (as the engine already does), or
# (b) teach write_overlay a pack-aware template that preserves the remote base
# + patches. TODO(decoupling): make write_overlay overlay-structure-aware.
function write_overlay() {
    local version_comment="# Promoted from releases/$VERSION.yaml by scripts/release/promote.sh -- DIGEST COPY, no rebuild (#702)."
    local header="apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: memql

resources:
  - ../../base
"
    local images; images="$(render_images_block)"
    local content="$version_comment
$header
$images"
    if [ "$DRY_RUN" = true ]; then
        plan "write $OVERLAY/kustomization.yaml:"
        echo "$content"
        return 0
    fi
    printf '%s\n' "$content" > "$OVERLAY/kustomization.yaml"
    info "wrote $OVERLAY/kustomization.yaml (version $VERSION)."
    info "next: PR it; Argo CD reconciles $ENV. drift-check --rendered --env=$ENV should pass."
}

function main() {
    parse_arguments "$@"
    validate_inputs
    info "promoting $VERSION -> $ENV (digest copy from $LOCKFILE)"
    write_overlay
}

main "$@"
