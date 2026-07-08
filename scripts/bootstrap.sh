#!/usr/bin/env bash
set -euo pipefail

# Script: scripts/bootstrap.sh
# Purpose: Stamp a memQL product workspace from this template checkout.
#
# The checkout directory of this repo IS the workspace root. Stamping:
#   1. validates parameters,
#   2. clones the shared engine (memql) and the cockpit (memql-cockpit)
#      as subdirectory checkouts (each its own git repo, ignored by the
#      workspace repo),
#   3. stamps the product carrier and client repos from templates/carrier
#      and templates/client (token substitution; a missing payload is
#      reported, not fatal),
#   4. substitutes the __PRODUCT__ / __PRODUCT_ORG__ / __DOMAIN__ /
#      __ENGINE_VERSION__ tokens across the workspace-root docs and
#      regenerates go.work from the checkouts that exist,
#   5. git-inits the stamped product repos (and optionally creates +
#      pushes GitHub repos with --create-repos=github).
#
# This is a CAPABILITY SCRIPT (docs: the engine repo's
# docs/internal/design/capability-script-contract.md): non-interactive,
# --flag=value params, exactly one JSON envelope on stdout, human logs
# on stderr, honest exit codes (0 ok / 2 bad param / 3 refused /
# 4 prerequisite missing / 5 op failed).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/capability.sh"

cap_init "project.bootstrap" "Stamp a memQL product workspace: clone engine + cockpit, scaffold product repos, substitute tokens, regenerate go.work."
cap_spec_param "product"        "product name (required; ^[a-z][a-z0-9-]*$; e.g. 'acme')"
cap_spec_param "product-org"    "GitHub org/user owning the product repos (required; e.g. 'acme-io')"
cap_spec_param "domain"         "local front-door domain (default: local.znas.io)"
cap_spec_param "engine-version" "engine ref to pin (default: latest release tag, else main)"
cap_spec_param "engine-repo"    "engine git URL (default: https://github.com/znasllc-io/memql.git)"
cap_spec_param "cockpit-repo"   "cockpit git URL (default: https://github.com/znasllc-io/memql-cockpit.git)"
cap_spec_param "create-repos"   "create + push GitHub repos for stamped product repos: none|github (default: none)"
cap_spec_param "shallow"        "clone engine/cockpit with --depth 1 (flag; for CI smoke runs)"
cap_spec_param "dry-run"        "report the stamp plan without changing anything (flag)"
cap_spec_param "go-module"      "stamp the carrier (Go module + go.work) variant instead of the DSL-first bundle (flag; only for products that need bespoke Go)"

#=============================================================================
# CONFIGURATION
#=============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Which product payloads to stamp. Default = the DSL-first bundle (platform
# consolidation memql#2472): no product Go, no go.work, runtime DSL delivery.
# --go-module switches to the carrier variant (Go module + go.work) for the
# rare product that needs bespoke Go. Set in main() after the flag is read.
TEMPLATE_DIRS=("bundle" "client")
TOKEN_FILES=("README.md" "ONBOARDING.md")

#=============================================================================
# FUNCTIONS
#=============================================================================

function require_prerequisites() {
    command -v git >/dev/null 2>&1 || cap_fail 4 "git is not installed"
    if [[ "$CREATE_REPOS" == "github" ]]; then
        command -v gh >/dev/null 2>&1 || cap_fail 4 "--create-repos=github requires the gh CLI"
        gh auth status >/dev/null 2>&1 || cap_fail 4 "--create-repos=github requires an authenticated gh (run: gh auth login)"
    fi
}

function validate_params() {
    cap_require product "$PRODUCT"
    cap_require product-org "$PRODUCT_ORG"
    [[ "$PRODUCT" =~ ^[a-z][a-z0-9-]*$ ]] \
        || cap_fail 2 "invalid --product '$PRODUCT' (want ^[a-z][a-z0-9-]*$)"
    [[ "$PRODUCT_ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] \
        || cap_fail 2 "invalid --product-org '$PRODUCT_ORG'"
    case "$CREATE_REPOS" in none|github) ;; *)
        cap_fail 2 "invalid --create-repos '$CREATE_REPOS' (want none|github)" ;;
    esac
    [[ "$PRODUCT" == "memql" || "$PRODUCT" == "memql-cockpit" ]] \
        && cap_fail 2 "--product '$PRODUCT' collides with a reserved checkout name"
    return 0
}

# resolve_engine_version -> echoes the ref to pin. Explicit param wins;
# otherwise the latest semver tag on the engine repo; otherwise main.
function resolve_engine_version() {
    if [[ -n "$ENGINE_VERSION" ]]; then
        printf '%s' "$ENGINE_VERSION"
        return
    fi
    local latest
    latest="$(git ls-remote --tags --refs "$ENGINE_REPO" 2>/dev/null \
        | awk -F/ '{print $NF}' \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1 || true)"
    printf '%s' "${latest:-main}"
}

# clone_repo <url> <dir> <ref> -- idempotent subdirectory clone.
function clone_repo() {
    local url="$1" dir="$2" ref="$3"
    if [[ -d "$ROOT/$dir/.git" ]]; then
        cap_info "$dir/ already checked out; leaving as-is"
        return 0
    fi
    cap_step "cloning $url -> $dir/ (ref: $ref)"
    local args=(clone)
    [[ -n "$SHALLOW" ]] && args+=(--depth 1)
    # Tags and branches clone directly; a bare SHA needs a full clone + checkout.
    if git "${args[@]}" --branch "$ref" "$url" "$ROOT/$dir" 2>/dev/null; then
        :
    else
        git clone "$url" "$ROOT/$dir"
        git -C "$ROOT/$dir" checkout "$ref"
    fi
    cap_changed
}

# stamp_tree <src> <dst> -- copies a payload tree substituting all four
# tokens in file CONTENTS and file/dir NAMES. dst must not already exist.
function stamp_tree() {
    local src="$1" dst="$2"
    [[ -d "$dst" ]] && cap_fail 5 "stamp target already exists: $dst"
    cap_step "stamping $(basename "$src") -> $dst"
    mkdir -p "$dst"
    ( cd "$src" && find . -type d ) | while IFS= read -r d; do
        mkdir -p "$dst/$(substitute_tokens_in_string "${d#./}")"
    done
    ( cd "$src" && find . -type f ) | while IFS= read -r f; do
        local rel="${f#./}"
        local out
        out="$dst/$(substitute_tokens_in_string "$rel")"
        substitute_tokens_in_file "$src/$rel" "$out"
        # Preserve the executable bit (scripts in the payload). Use an `if`
        # rather than `[[ -x ]] && chmod`: the latter, as the loop body's last
        # statement, leaves the loop (and its `find | while` pipeline) with a
        # non-zero exit status whenever the FINAL file is non-executable -- which
        # trips `set -e` and aborts the stamp. An if-block always exits 0.
        if [[ -x "$src/$rel" ]]; then
            chmod +x "$out"
        fi
    done
    cap_changed
}

function substitute_tokens_in_string() {
    local s="$1"
    s="${s//__PRODUCT__/$PRODUCT}"
    s="${s//__PRODUCT_ORG__/$PRODUCT_ORG}"
    s="${s//__DOMAIN__/$DOMAIN}"
    s="${s//__ENGINE_VERSION__/$RESOLVED_ENGINE_VERSION}"
    printf '%s' "$s"
}

function substitute_tokens_in_file() {
    local in="$1" out="$2"
    sed -e "s|__PRODUCT__|$PRODUCT|g" \
        -e "s|__PRODUCT_ORG__|$PRODUCT_ORG|g" \
        -e "s|__DOMAIN__|$DOMAIN|g" \
        -e "s|__ENGINE_VERSION__|$RESOLVED_ENGINE_VERSION|g" \
        "$in" > "$out"
}

# stamp_payloads -- templates/carrier -> <product>-carrier/,
# templates/client -> <product>-client/. A missing payload is reported,
# not fatal.
function stamp_payloads() {
    local name stamped=()
    for name in "${TEMPLATE_DIRS[@]}"; do
        local src="$ROOT/templates/$name"
        local dst="$ROOT/${PRODUCT}-${name}"
        if [[ ! -d "$src" ]]; then
            cap_warn "templates/$name not present -- skipping"
            continue
        fi
        # Idempotent re-run: an already-stamped product repo is left as-is
        # (matching clone_repo's behavior for the engine/cockpit checkouts), so
        # re-running bootstrap on a set-up workspace is a no-op rather than a
        # "stamp target already exists" failure. Remove the dir for a fresh stamp.
        if [[ -d "$dst" ]]; then
            cap_info "${PRODUCT}-${name}/ already stamped; leaving as-is"
            stamped+=("$dst")
            continue
        fi
        stamp_tree "$src" "$dst"
        stamped+=("$dst")
    done
    STAMPED_REPOS=("${stamped[@]:-}")
}

# stamp_root_docs -- substitute tokens in the workspace root's own
# committed docs so they read product-specific after stamping.
function stamp_root_docs() {
    local f tmp
    for f in "${TOKEN_FILES[@]}"; do
        [[ -f "$ROOT/$f" ]] || continue
        tmp="$(mktemp)"
        substitute_tokens_in_file "$ROOT/$f" "$tmp"
        if ! cmp -s "$tmp" "$ROOT/$f"; then
            mv "$tmp" "$ROOT/$f"
            cap_changed
        else
            rm -f "$tmp"
        fi
    done
}

# regenerate_go_work -- writes go.work from the checkouts that actually
# exist (engine + cockpit + carrier when stamped). The client repo is not
# a Go module and never appears.
function regenerate_go_work() {
    local go_directive
    go_directive="$(grep -E '^go [0-9]' "$ROOT/go.work" | head -1 || echo "go 1.26.3")"
    {
        printf '// Workspace manifest generated by scripts/bootstrap.sh.\n'
        printf '%s\n\nuse (\n' "$go_directive"
        printf '\t./memql\n'
        [[ -d "$ROOT/${PRODUCT}-carrier" ]] && printf '\t./%s-carrier\n' "$PRODUCT"
        printf '\t./memql-cockpit\n'
        printf ')\n'
    } > "$ROOT/go.work"
    cap_changed
}

# generate_carrier_gosum -- a freshly stamped carrier ships no go.sum
# (dependency hashes resolve at stamp time against the cloned engine
# sibling), but the carrier Dockerfile COPYs it and the first CI build
# expects it committed. Generate it at stamp time when the Go toolchain
# is available so the initial commit is complete; otherwise warn -- the
# first local `go build` generates it and it should be committed then.
function generate_carrier_gosum() {
    local carrier="$ROOT/${PRODUCT}-carrier"
    [[ -d "$carrier" ]] || return 0
    [[ -f "$carrier/go.sum" ]] && return 0
    if command -v go >/dev/null 2>&1; then
        cap_step "go mod tidy (generate ${PRODUCT}-carrier/go.sum)"
        if (cd "$carrier" && go mod tidy >/dev/null 2>&1); then
            cap_changed
        else
            cap_warn "go mod tidy failed in ${PRODUCT}-carrier; run it manually and commit go.sum"
        fi
    else
        cap_warn "Go toolchain not found; run 'go mod tidy' in ${PRODUCT}-carrier and commit go.sum before the first docker build"
    fi
}

# append_product_gitignore -- the stamped product repos are sibling git
# repos inside the workspace root; the workspace repo must ignore them.
function append_product_gitignore() {
    local line
    for line in "/${PRODUCT}-carrier/" "/${PRODUCT}-client/"; do
        grep -qxF "$line" "$ROOT/.gitignore" 2>/dev/null || {
            printf '%s\n' "$line" >> "$ROOT/.gitignore"
            cap_changed
        }
    done
}

# init_product_repos -- git init + first commit per stamped repo; with
# --create-repos=github also create the private remote and push.
function init_product_repos() {
    local dir
    # NOTE: ${arr[@]:-} keeps bash 3.2 (macOS default) happy under set -u.
    for dir in "${STAMPED_REPOS[@]:-}"; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        if [[ ! -d "$dir/.git" ]]; then
            cap_step "git init $(basename "$dir")"
            git -C "$dir" init -q -b main
            git -C "$dir" add -A
            # Author the scaffolding commit with the ambient git identity when
            # one is configured; otherwise fall back to a stamped identity so
            # the commit never fails on a machine (or a fresh CI runner) with no
            # user.name/user.email set. A capability script must run identically
            # everywhere -- it cannot depend on the caller's git config.
            local msg="Initial commit (stamped from znasllc-io/memql-project)"
            if git -C "$dir" config user.email >/dev/null 2>&1 \
                && git -C "$dir" config user.name >/dev/null 2>&1; then
                git -C "$dir" commit -q -m "$msg"
            else
                git -C "$dir" \
                    -c "user.name=memql-project bootstrap" \
                    -c "user.email=bootstrap@memql-project.local" \
                    commit -q -m "$msg"
            fi
            cap_changed
        fi
        if [[ "$CREATE_REPOS" == "github" ]]; then
            local repo
            repo="${PRODUCT_ORG}/$(basename "$dir")"
            cap_step "gh repo create $repo (private) + push"
            gh repo create "$repo" --private --source "$dir" --push \
                || cap_fail 5 "gh repo create failed for $repo"
            cap_changed
        fi
    done
}

function print_dry_run_plan() {
    cap_info "DRY RUN -- no changes will be made"
    cap_info "workspace root:   $ROOT"
    cap_info "engine:           $ENGINE_REPO @ $RESOLVED_ENGINE_VERSION -> memql/"
    cap_info "cockpit:          $COCKPIT_REPO -> memql-cockpit/"
    cap_info "product model:    $( [[ -n "$GO_MODULE" ]] && echo 'carrier (Go module + go.work)' || echo 'DSL-first bundle (no product Go)')"
    for name in "${TEMPLATE_DIRS[@]}"; do
        cap_info "$(printf '%-16s' "${name} payload:") templates/${name} -> ${PRODUCT}-${name}/ $( [[ -d "$ROOT/templates/${name}" ]] || echo '(payload absent -- skip)')"
    done
    cap_info "front door:       https://{identity,bff,app}.$DOMAIN"
    cap_info "create repos:     $CREATE_REPOS"
}

function emit_result() {
    cap_result_set product "$PRODUCT"
    cap_result_set productOrg "$PRODUCT_ORG"
    cap_result_set domain "$DOMAIN"
    cap_result_set engineVersion "$RESOLVED_ENGINE_VERSION"
    cap_result_set workspaceRoot "$ROOT"
    local repos_json="[" first=1 dir
    for dir in "${STAMPED_REPOS[@]:-}"; do
        [[ -n "$dir" ]] || continue
        [[ "$first" == "1" ]] || repos_json+=","
        first=0
        repos_json+="\"$(cap_json_escape "$(basename "$dir")")\""
    done
    repos_json+="]"
    cap_result_set_raw stampedRepos "$repos_json"
    cap_result_set_raw dryRun "$( [[ -n "$DRY_RUN" ]] && echo true || echo false )"
}

function main() {
    cap_handle_meta "$@"
    cap_parse_flags "$@"

    PRODUCT="$(cap_param product "")"
    PRODUCT_ORG="$(cap_param product-org "")"
    DOMAIN="$(cap_param domain "local.znas.io")"
    ENGINE_VERSION="$(cap_param engine-version "")"
    ENGINE_REPO="$(cap_param engine-repo "https://github.com/znasllc-io/memql.git")"
    COCKPIT_REPO="$(cap_param cockpit-repo "https://github.com/znasllc-io/memql-cockpit.git")"
    CREATE_REPOS="$(cap_param create-repos "none")"
    SHALLOW="$(cap_flag shallow)"
    DRY_RUN="$(cap_flag dry-run)"
    GO_MODULE="$(cap_flag go-module)"
    # DSL-first bundle by default; carrier (Go module) only when --go-module.
    if [[ -n "$GO_MODULE" ]]; then
        TEMPLATE_DIRS=("carrier" "client")
    else
        TEMPLATE_DIRS=("bundle" "client")
    fi
    STAMPED_REPOS=()

    validate_params
    require_prerequisites
    RESOLVED_ENGINE_VERSION="$(resolve_engine_version)"

    if [[ -n "$DRY_RUN" ]]; then
        print_dry_run_plan
        emit_result
        cap_ok
    fi

    clone_repo "$ENGINE_REPO" "memql" "$RESOLVED_ENGINE_VERSION"
    clone_repo "$COCKPIT_REPO" "memql-cockpit" "main"
    stamp_payloads
    stamp_root_docs
    regenerate_go_work
    generate_carrier_gosum
    append_product_gitignore
    init_product_repos

    cap_info "workspace stamped. Next: cd ${PRODUCT}-carrier && make up"
    emit_result
    cap_ok
}

#=============================================================================
# ENTRY POINT
#=============================================================================

main "$@"
