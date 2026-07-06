#!/usr/bin/env bash
#
# scripts/release/release.sh
# ==========================
#
# Cut an IMMUTABLE memql-bff-__PRODUCT__ CARRIER image for the Azure
# deployment foundation (__PRODUCT_ORG__/__PRODUCT__-carrier#79, epic
# znasllc-io/memql#491).
#
# This repo is the deployable __PRODUCT__ BFF carrier: the memQL engine
# (github.com/znasllc-io/memql, pinned in go.mod) PLUS the __PRODUCT__
# DSL + integrations, compiled into one node binary. The pin chain is:
#
#     __PRODUCT__  --pins-->  memql-bff-__PRODUCT__:X.Y.Z   (this image)
#                                     |
#                                     +-- go.mod require znasllc-io/memql v0.9.0
#
# Given VERSION (semver, e.g. 0.9.0) and the current short git SHA this
# script builds, from the repo's Dockerfile, an image tagged:
#
#     <REGISTRY/>memql-bff-__PRODUCT__:X.Y.Z   (the pinnable, immutable tag)
#
# and stamps the build with the exact source revision as an OCI label
# (org.opencontainers.image.revision=<sha>) so the image is traceable
# back to a commit. The X.Y.Z tag is treated as write-once: pushing
# over an existing tag is refused unless --allow-overwrite is given,
# which is what makes the tag a trustworthy pin for __PRODUCT__.
#
# DOCKER BUILD CONTEXT: the Dockerfile's build context spans BOTH
# memql/ AND memql-bff-__PRODUCT__/ as sibling directories under the
# context root, because go.mod has a `replace ... => ../memql`
# directive pointing at the local sibling. The context root is
# therefore the WORKSPACE PARENT (the directory that holds both
# memql/ and memql-bff-__PRODUCT__/), and the dockerfile path is
# memql-bff-__PRODUCT__/Dockerfile -- mirroring the docker-compose
# wiring documented at the top of the Dockerfile.
#
# Per the repo + global Skills+Scripts convention (CLAUDE.md): pure
# function-based structure -- one function per responsibility, with
# main() at the bottom calling them in order. Supports --help and a
# --dry-run that prints the full plan and builds/pushes nothing.

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================

# Shared Basic ACR from the locked epic architecture (#491). ACR names
# are global + alphanumeric-only (no dashes); the login server is
# <name>.azurecr.io. Empty REGISTRY builds a local-only image
# (memql-bff-__PRODUCT__:X.Y.Z with no registry prefix), which is the
# default so the target works before a subscription exists.
readonly DEFAULT_ACR_NAME="acrmemql"
readonly IMAGE_NAME="memql-bff-__PRODUCT__"
# Dockerfile path + context root are relative to the WORKSPACE PARENT
# (resolved below). The carrier Dockerfile needs both sibling trees in
# context for the `replace ../memql` to resolve.
readonly DOCKERFILE_REL="memql-bff-__PRODUCT__/Dockerfile"

#=============================================================================
# FUNCTIONS
#=============================================================================

function show_help() {
    cat <<EOF
Usage: scripts/release/release.sh [options]

Cut an immutable memql-bff-__PRODUCT__:X.Y.Z carrier image (VERSION +
short git SHA) that __PRODUCT__ pins via its carrier-version file
(__PRODUCT__#140). The image bundles the memQL engine (pinned in go.mod)
with the __PRODUCT__ DSL + integrations.

Options:
    --version=X.Y.Z     Semver to tag the image with. Default: the
                        semver prefix of the VERSION file (the part
                        before the first '-').
    --registry=HOST     Container registry login server to prefix +
                        push to (e.g. acrmemql.azurecr.io). Empty =
                        build a local-only image, no push.
    --acr=NAME          Shorthand: derive --registry from an ACR name
                        (NAME.azurecr.io). Default ACR: $DEFAULT_ACR_NAME
                        (only used if --registry/--acr is given).
    --push              Push the built tag to the registry. Requires
                        a registry. Refused if the tag already exists
                        unless --allow-overwrite.
    --build-tags=TAGS   Go build-tag set the carrier compiles for
                        (Dockerfile ARG BUILD_TAGS). Default: bff.
                        E.g. --build-tags=agent for an agent-flavoured
                        carrier that still bundles the __PRODUCT__ DSL.
    --allow-overwrite   Permit pushing over an existing X.Y.Z tag.
                        Off by default: release tags are immutable.
    --dry-run           Print the full plan; build/push nothing.
    --help              Show this help.

Examples:
    # Local immutable carrier image from the VERSION file's semver prefix:
    scripts/release/release.sh

    # Explicit version, build + push to the shared ACR:
    scripts/release/release.sh --version=0.9.0 --acr=$DEFAULT_ACR_NAME --push

    # Plan only:
    scripts/release/release.sh --version=0.9.0 --acr=$DEFAULT_ACR_NAME --push --dry-run
EOF
}

function parse_arguments() {
    VERSION=""
    REGISTRY=""
    ACR_NAME=""
    BUILD_TAGS="bff"
    PUSH=false
    ALLOW_OVERWRITE=false
    DRY_RUN=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version=*)         VERSION="${1#*=}" ;;
            --registry=*)        REGISTRY="${1#*=}" ;;
            --acr=*)             ACR_NAME="${1#*=}" ;;
            --build-tags=*)      BUILD_TAGS="${1#*=}" ;;
            --push)              PUSH=true ;;
            --allow-overwrite)   ALLOW_OVERWRITE=true ;;
            --dry-run)           DRY_RUN=true ;;
            --help)              show_help; exit 0 ;;
            *)
                echo "ERROR: unknown option: $1" >&2
                show_help >&2
                exit 1
                ;;
        esac
        shift
    done
}

function resolve_repo_root() {
    # This script lives at scripts/release/; the repo root is two
    # directories up. Resolve it so the target works from anywhere.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${here}/../.." && pwd)"
    # The Dockerfile's build context is the workspace parent -- the
    # directory that holds both memql/ and memql-bff-__PRODUCT__/.
    CONTEXT_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
}

function resolve_version() {
    if [[ -z "$VERSION" ]]; then
        if [[ ! -f "${REPO_ROOT}/VERSION" ]]; then
            echo "ERROR: no --version given and no VERSION file found" >&2
            exit 1
        fi
        # The VERSION file is plain "X.Y.Z" post the v0.9.0 reset; the
        # cut strips any legacy "-<epoch>" dev suffix as a safety net.
        VERSION="$(head -n1 "${REPO_ROOT}/VERSION" | cut -d- -f1)"
    fi

    # Validate strict semver X.Y.Z (the immutable image tag must be a
    # clean three-part version -- no pre-release/epoch suffix).
    if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: --version must be clean semver X.Y.Z (got: '$VERSION')" >&2
        echo "       The VERSION file carries a clean semver baseline; a" >&2
        echo "       release tag must drop any epoch suffix. Pass" >&2
        echo "       --version=X.Y.Z explicitly." >&2
        exit 1
    fi
}

function resolve_sha() {
    # Short SHA stamps the image's revision label so an immutable X.Y.Z
    # tag is traceable back to an exact commit. A dirty tree is flagged
    # so we never cut a "clean" release from uncommitted work.
    SHORT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null)" ]]; then
        SHORT_SHA="${SHORT_SHA}-dirty"
    fi
}

function resolve_registry() {
    # --registry wins; else derive from --acr; else (neither given)
    # leave REGISTRY empty for a local-only build.
    if [[ -z "$REGISTRY" && -n "$ACR_NAME" ]]; then
        REGISTRY="${ACR_NAME}.azurecr.io"
    fi

    if [[ -n "$REGISTRY" ]]; then
        IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
    else
        IMAGE_REF="${IMAGE_NAME}:${VERSION}"
    fi
}

function validate_push() {
    if [[ "$PUSH" == true && -z "$REGISTRY" ]]; then
        echo "ERROR: --push requires a registry (--registry=HOST or --acr=NAME)" >&2
        exit 1
    fi
}

function check_prerequisites() {
    # A dry-run only prints the plan -- it needs neither docker nor the
    # sibling tree, so skip the environment checks and keep it runnable
    # from CI (go test) where neither is guaranteed present.
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker is not installed" >&2
        exit 1
    fi
    # The carrier build context needs the sibling memql/ tree (the
    # `replace ../memql` source). Fail early with a clear message if
    # the workspace layout isn't present.
    if [[ ! -d "${CONTEXT_ROOT}/memql" ]]; then
        echo "ERROR: sibling memql/ checkout not found at ${CONTEXT_ROOT}/memql" >&2
        echo "       The carrier Dockerfile resolves 'replace ../memql' from a" >&2
        echo "       sibling tree, so the build context must hold both" >&2
        echo "       memql/ and memql-bff-__PRODUCT__/." >&2
        exit 1
    fi
}

function print_plan() {
    echo "========================================="
    echo "memQL BFF (__PRODUCT__) carrier release image"
    echo "========================================="
    echo "Version:    $VERSION"
    echo "Source SHA: $SHORT_SHA"
    echo "Image:      $IMAGE_REF"
    echo "Build tags: $BUILD_TAGS"
    echo "Dockerfile: $DOCKERFILE_REL"
    echo "Context:    $CONTEXT_ROOT"
    echo "Push:       $PUSH"
    echo "Overwrite:  $ALLOW_OVERWRITE"
    echo "Dry run:    $DRY_RUN"
    echo "========================================="
}

function ensure_tag_immutable() {
    # Only meaningful when pushing to a real registry. Refuse to clobber
    # an existing X.Y.Z tag unless explicitly allowed -- that is what
    # makes the tag a trustworthy pin for __PRODUCT__ (__PRODUCT__#140).
    if [[ "$PUSH" != true || -z "$REGISTRY" || "$ALLOW_OVERWRITE" == true ]]; then
        return 0
    fi
    if docker manifest inspect "$IMAGE_REF" >/dev/null 2>&1; then
        echo "ERROR: tag already exists in registry: $IMAGE_REF" >&2
        echo "       Release tags are immutable. Bump --version, or pass" >&2
        echo "       --allow-overwrite to deliberately re-cut this tag." >&2
        exit 1
    fi
}

function build_image() {
    local -a build_args=(
        docker build
        --platform "${BUILD_PLATFORM:-linux/amd64}"
        -f "${CONTEXT_ROOT}/${DOCKERFILE_REL}"
        -t "$IMAGE_REF"
        --build-arg "BUILD_TAGS=${BUILD_TAGS}"
        --label "org.opencontainers.image.version=${VERSION}"
        --label "org.opencontainers.image.revision=${SHORT_SHA}"
        "${CONTEXT_ROOT}"
    )

    if [[ "$DRY_RUN" == true ]]; then
        echo "[plan] ${build_args[*]}"
        return 0
    fi
    # Fail-fast: an explicit exit preserves the docker exit code even in
    # contexts where -e might be suppressed (e.g. subshell assignments).
    if ! "${build_args[@]}"; then
        echo "ERROR: docker build failed -- aborting before push" >&2
        exit 1
    fi
}

function push_image() {
    if [[ "$PUSH" != true ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "[plan] docker push ${IMAGE_REF}"
        return 0
    fi
    # Fail-fast: abort before printing success if the push fails.
    if ! docker push "$IMAGE_REF"; then
        echo "ERROR: docker push failed -- image may not be in the registry" >&2
        exit 1
    fi
}

function print_result() {
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY RUN complete -- built/pushed nothing. Planned image: $IMAGE_REF"
    else
        echo "Carrier image ready: $IMAGE_REF (revision ${SHORT_SHA})"
        if [[ "$PUSH" == true ]]; then
            echo "Pushed. __PRODUCT__ pins this via its carrier-version file=${VERSION} (__PRODUCT__#140)."
        else
            echo "Local only. Re-run with --push (and a registry) to publish."
        fi
    fi
}

function main() {
    parse_arguments "$@"
    resolve_repo_root
    resolve_version
    resolve_sha
    resolve_registry
    validate_push
    check_prerequisites
    print_plan
    ensure_tag_immutable
    build_image
    push_image
    print_result
}

#=============================================================================
# ENTRY POINT
#=============================================================================

main "$@"
