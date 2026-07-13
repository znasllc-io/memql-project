#!/usr/bin/env bash
set -euo pipefail

# Script: scripts/init.sh
# Purpose: Stamp THIS template checkout in place into a concrete memQL product.
#
# Step-5 consolidation (memql-project#10): this repo IS the product repo. "Use
# this template" + init.sh replaces the old workspace-root + bootstrap.sh model
# (which stamped sibling bundle/client repos). init.sh, on the current checkout:
#   1. writes product.env (the single source of product identity every
#      operational file -- Makefiles, scripts, CI -- reads);
#   2. renames dsl/__PRODUCT__/ -> dsl/<product>/ and the argocd app files;
#   3. substitutes the __PRODUCT__ / __PRODUCT_ORG__ / __DOMAIN__ / __ENGINE_REF__
#      / __REGISTRY__ tokens ONLY where a tool genuinely cannot read product.env
#      at runtime (dsl file contents, k8s/argocd manifest fields kustomize can't
#      inject, the client package name/scope + boot defaults, ONBOARDING.md,
#      CLAUDE.md); every operational file stays byte-identical so a later
#      `git merge template/main` never conflicts on plumbing;
#   4. clones ../memql (at --engine-ref) and ../memql-cockpit (at --cockpit-ref)
#      as SIBLINGS in the PARENT directory (the workspace);
#   5. prunes template-only artifacts (template-ci.yml, product.env.example) and
#      replaces the template README with a product README stub.
#
# CAPABILITY SCRIPT (the engine's docs/internal/design/capability-script-contract.md):
# non-interactive, --flag=value params, exactly one JSON envelope on stdout,
# human logs on stderr, honest exit codes (0 ok / 2 bad param / 3 refused /
# 4 prerequisite missing / 5 op failed), honest `changed`, idempotent re-runs.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/capability.sh"

cap_init "product.init" "Stamp this template checkout in place into a concrete memQL product: write product.env, rename + substitute tokens, clone engine + cockpit siblings, prune template artifacts."
cap_spec_param "product"      "product name (required; ^[a-z][a-z0-9-]*$; e.g. 'acme')"
cap_spec_param "product-org"  "GitHub org/user owning this product repo (required; e.g. 'acme-io')"
cap_spec_param "domain"       "local front-door domain (default: local.znas.io)"
cap_spec_param "engine-ref"   "engine ref to pin (default: latest engine release tag, else main)"
cap_spec_param "registry"     "container registry for the product bundle + client images (default: empty = local-only)"
cap_spec_param "cockpit-ref"  "cockpit ref to clone (default: main)"
cap_spec_param "skip-clones"  "do not clone the engine/cockpit siblings (flag; for CI + offline runs)"
cap_spec_param "dry-run"      "report the stamp plan without changing anything (flag)"

#=============================================================================
# CONFIGURATION
#=============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(cd "$ROOT/.." && pwd)"      # the workspace: engine + cockpit clone here
ENGINE_REPO="https://github.com/znasllc-io/memql.git"
COCKPIT_REPO="https://github.com/znasllc-io/memql-cockpit.git"

# Unknown-flag allowlist. The vendored capability.sh cap_parse_flags accepts ANY
# --flag (it only rejects positionals); this script enforces its own surface so
# a typo'd flag fails loudly (exit 2) instead of being silently ignored. Upstream
# fix -- making cap_parse_flags reject unknown flags against the declared spec --
# is tracked in znasllc-io/memql#2508; drop this local check when it lands.
CAP_KNOWN_FLAGS=" product product-org domain engine-ref registry cockpit-ref skip-clones dry-run help print-spec params-stdin "

# Operational files init must NEVER touch (byte-identical template<->product, so
# `git merge template/main` stays clean). Paths are relative to ROOT; a trailing
# slash marks a directory prefix. README.md is handled separately (replaced).
CAP_SKIP_PATHS=(
    ".git/"
    "scripts/"
    ".github/"
    "client/scripts/"
    "Makefile"
    "client/Makefile"
    ".gitignore"
    "client/.gitignore"
    "LICENSE"
    "product.env"
    "product.env.example"
    "README.md"
)

#=============================================================================
# FUNCTIONS
#=============================================================================

# reject_unknown_flags "$@" -- exit 2 on any --flag not in CAP_KNOWN_FLAGS.
function reject_unknown_flags() {
    local a name
    for a in "$@"; do
        case "$a" in
            --*=*) name="${a%%=*}"; name="${name#--}" ;;
            --*)   name="${a#--}" ;;
            *)     cap_fail 2 "unexpected positional argument: $a" ;;
        esac
        case "$CAP_KNOWN_FLAGS" in
            *" $name "*) ;;
            *) cap_fail 2 "unknown flag: --$name (see --help; local allowlist per znasllc-io/memql#2508)" ;;
        esac
    done
}

function require_prerequisites() {
    command -v git >/dev/null 2>&1 || cap_fail 4 "git is not installed"
}

function validate_params() {
    cap_require product "$PRODUCT"
    cap_require product-org "$PRODUCT_ORG"
    [[ "$PRODUCT" =~ ^[a-z][a-z0-9-]*$ ]] \
        || cap_fail 2 "invalid --product '$PRODUCT' (want ^[a-z][a-z0-9-]*$)"
    [[ "$PRODUCT_ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] \
        || cap_fail 2 "invalid --product-org '$PRODUCT_ORG'"
    [[ "$PRODUCT" == "memql" || "$PRODUCT" == "memql-cockpit" ]] \
        && cap_fail 2 "--product '$PRODUCT' collides with a reserved sibling checkout name"
    return 0
}

# resolve_engine_ref -> echoes the ref to pin. Explicit param wins; else the
# latest semver tag on the engine repo; else main.
function resolve_engine_ref() {
    if [[ -n "$ENGINE_REF" ]]; then printf '%s' "$ENGINE_REF"; return; fi
    local latest
    latest="$(git ls-remote --tags --refs "$ENGINE_REPO" 2>/dev/null \
        | awk -F/ '{print $NF}' \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1 || true)"
    printf '%s' "${latest:-main}"
}

# substitute_tokens_in_string <string> -- for path renames.
function substitute_tokens_in_string() {
    local s="$1"
    s="${s//__PRODUCT__/$PRODUCT}"
    s="${s//__PRODUCT_ORG__/$PRODUCT_ORG}"
    s="${s//__DOMAIN__/$DOMAIN}"
    s="${s//__ENGINE_REF__/$RESOLVED_ENGINE_REF}"
    s="${s//__REGISTRY__/$REGISTRY_VALUE}"
    printf '%s' "$s"
}

# sed_token_program -- the shared sed expression list (used for file contents).
# __REGISTRY__ uses REGISTRY_MANIFEST, which is the real registry when set and a
# fail-closed placeholder (registry.example.com) when local-only, so the
# staging/prod overlays always render a VALID image ref (no leading-slash name)
# even though product.env REGISTRY stays empty for a local-only product.
function sed_token_program() {
    printf 's|__PRODUCT_ORG__|%s|g; s|__PRODUCT__|%s|g; s|__DOMAIN__|%s|g; s|__ENGINE_REF__|%s|g; s|__REGISTRY__|%s|g' \
        "$PRODUCT_ORG" "$PRODUCT" "$DOMAIN" "$RESOLVED_ENGINE_REF" "$REGISTRY_MANIFEST"
}

# is_skipped <relpath> -- true if the path is an operational file/dir init must
# not substitute.
function is_skipped() {
    local rel="$1" p
    for p in "${CAP_SKIP_PATHS[@]}"; do
        if [[ "$p" == */ ]]; then
            [[ "$rel" == "$p"* ]] && return 0
        else
            [[ "$rel" == "$p" ]] && return 0
        fi
    done
    return 1
}

# write_product_env -- the single source of product identity. Idempotent: only
# rewritten when the content differs.
function write_product_env() {
    local target="$ROOT/product.env" tmp
    tmp="$(mktemp)"
    {
        printf '# Product identity, written by scripts/init.sh. Operational files\n'
        printf '# (Makefiles, scripts, CI) read this; keep it in sync by hand.\n'
        printf 'PRODUCT=%s\n' "$PRODUCT"
        printf 'PRODUCT_ORG=%s\n' "$PRODUCT_ORG"
        printf 'DOMAIN=%s\n' "$DOMAIN"
        printf 'ENGINE_REF=%s\n' "$RESOLVED_ENGINE_REF"
        printf 'REGISTRY=%s\n' "$REGISTRY_VALUE"
    } > "$tmp"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$target"
        cap_step "wrote product.env"
        cap_changed
    fi
}

# rename_token_paths -- rename the token-bearing paths (the dsl domain dir + the
# argocd app files). Idempotent: a already-renamed path is left as-is.
function rename_token_paths() {
    # dsl/__PRODUCT__/ -> dsl/<product>/
    if [[ -d "$ROOT/dsl/__PRODUCT__" ]]; then
        mv "$ROOT/dsl/__PRODUCT__" "$ROOT/dsl/$PRODUCT"
        cap_step "renamed dsl/__PRODUCT__/ -> dsl/$PRODUCT/"
        cap_changed
    fi
    # deploy/argocd/apps/__PRODUCT__-{staging,prod}.yaml
    local f base dst
    for f in "$ROOT"/deploy/argocd/apps/__PRODUCT__-*.yaml; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        dst="$ROOT/deploy/argocd/apps/$(substitute_tokens_in_string "$base")"
        mv "$f" "$dst"
        cap_step "renamed apps/$base -> $(basename "$dst")"
        cap_changed
    done
}

# substitute_tree -- substitute tokens in the CONTENTS of every non-skipped file
# that currently contains a token. Idempotent: a file with no tokens is a no-op.
function substitute_tree() {
    local prog rel tmp
    prog="$(sed_token_program)"
    # -print0/read -d '' keeps paths with spaces safe; bash 3.2 compatible.
    while IFS= read -r -d '' f; do
        rel="${f#"$ROOT"/}"
        is_skipped "$rel" && continue
        grep -q '__PRODUCT__\|__PRODUCT_ORG__\|__DOMAIN__\|__ENGINE_REF__\|__REGISTRY__' "$f" 2>/dev/null || continue
        tmp="$(mktemp)"
        sed -e "$prog" "$f" > "$tmp"
        if cmp -s "$tmp" "$f"; then
            rm -f "$tmp"
        else
            # Redirect into the existing file (not mv) so its mode is preserved.
            cat "$tmp" > "$f"
            rm -f "$tmp"
            cap_changed
        fi
    done < <(find "$ROOT" -type f -not -path '*/.git/*' -print0)
    cap_step "substituted tokens across the product tree"
}

# clone_sibling <url> <dir> <ref> -- idempotent sibling clone into PARENT.
function clone_sibling() {
    local url="$1" dir="$2" ref="$3" dest="$PARENT/$2"
    if [[ -d "$dest/.git" ]]; then
        cap_info "$dir/ already checked out at $dest; leaving as-is"
        return 0
    fi
    cap_step "cloning $url -> $dest (ref: $ref)"
    if git clone --branch "$ref" "$url" "$dest" 2>/dev/null; then
        :
    else
        git clone "$url" "$dest"
        git -C "$dest" checkout "$ref"
    fi
    cap_changed
}

function clone_siblings() {
    [[ -n "$SKIP_CLONES" ]] && { cap_info "--skip-clones: not cloning engine/cockpit"; return 0; }
    clone_sibling "$ENGINE_REPO"  "memql"         "$RESOLVED_ENGINE_REF"
    clone_sibling "$COCKPIT_REPO" "memql-cockpit" "$COCKPIT_REF"
}

# replace_readme -- swap the template README (a guide to the template) for a
# product README stub. Idempotent via cmp.
function replace_readme() {
    local target="$ROOT/README.md" tmp
    tmp="$(mktemp)"
    {
        printf '# %s\n\n' "$PRODUCT"
        printf 'A **memQL product** -- a DSL bundle + a client running on the shared,\n'
        printf 'product-agnostic [memQL engine](https://github.com/znasllc-io/memql). Stamped\n'
        printf 'from the [memql-project](https://github.com/znasllc-io/memql-project) template.\n\n'
        printf '## Layout\n\n'
        printf -- '- `dsl/%s/` -- the product DSL (.memql): concepts, queries, mutations,\n' "$PRODUCT"
        printf '  shapes, tools, automations. The whole product surface; no product Go.\n'
        printf -- '- `client/` -- the product frontend (Vite + React + TS SPA).\n'
        printf -- '- `deploy/` -- the DSL-bundle image (`Dockerfile.bundle`) + kustomize\n'
        printf '  overlays (local / staging / prod) + the ArgoCD project/app manifests.\n'
        printf -- '- `product.env` -- product identity every operational file reads.\n\n'
        printf '## Local stack\n\n'
        printf 'Requires the engine + cockpit checked out as siblings (`../memql`,\n'
        printf '`../memql-cockpit`) plus docker, k3d, kubectl, mkcert.\n\n'
        printf '```bash\n'
        printf 'make up        # engine mesh + this product (bff + SPA + DSL) on local k3d\n'
        printf 'make dev       # rebuild the DSL bundle and re-mount it on the bff\n'
        printf 'make status    # product Application + mesh status\n'
        printf 'make down      # tear down\n'
        printf 'cd client && make dev   # the SPA HMR inner loop (Vite on :8080)\n'
        printf '```\n\n'
        printf 'The front door serves https://identity.%s, https://bff.%s, https://app.%s.\n\n' "$DOMAIN" "$DOMAIN" "$DOMAIN"
        printf '## Staying in sync with the template\n\n'
        printf 'This repo was stamped from the template; operational files (Makefiles,\n'
        printf 'scripts, CI) are byte-identical to it and read `product.env`, so template\n'
        printf 'improvements merge cleanly:\n\n'
        printf '```bash\n'
        printf 'git remote add template https://github.com/znasllc-io/memql-project.git\n'
        printf 'git fetch template\n'
        printf 'git merge template/main --allow-unrelated-histories   # first time only\n'
        printf '```\n\n'
        printf 'See `ONBOARDING.md` for the development workflow and `CLAUDE.md` for the\n'
        printf 'repo agent guide.\n'
    } > "$tmp"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$target"
        cap_step "wrote product README stub"
        cap_changed
    fi
}

# prune_template_artifacts -- remove files only the template needs.
function prune_template_artifacts() {
    local f
    for f in ".github/workflows/template-ci.yml" "product.env.example"; do
        if [[ -e "$ROOT/$f" ]]; then
            rm -f "$ROOT/$f"
            cap_step "pruned $f"
            cap_changed
        fi
    done
}

function print_dry_run_plan() {
    cap_info "DRY RUN -- no changes will be made"
    cap_info "product repo root: $ROOT"
    cap_info "workspace (parent): $PARENT"
    cap_info "product:      $PRODUCT"
    cap_info "product org:  $PRODUCT_ORG"
    cap_info "domain:       $DOMAIN"
    cap_info "engine ref:   $RESOLVED_ENGINE_REF"
    cap_info "registry:     ${REGISTRY_VALUE:-<empty: local-only>}"
    cap_info "would write:  product.env"
    cap_info "would rename: dsl/__PRODUCT__/ -> dsl/$PRODUCT/, deploy/argocd/apps/__PRODUCT__-*.yaml"
    cap_info "would stamp:  dsl/, deploy/, client/ (src+manifests+docs), ONBOARDING.md, CLAUDE.md"
    cap_info "would prune:  .github/workflows/template-ci.yml, product.env.example; replace README.md with a product stub"
    if [[ -n "$SKIP_CLONES" ]]; then
        cap_info "would clone:  (skipped -- --skip-clones)"
    else
        cap_info "would clone:  $ENGINE_REPO@$RESOLVED_ENGINE_REF -> $PARENT/memql, $COCKPIT_REPO@$COCKPIT_REF -> $PARENT/memql-cockpit"
    fi
}

function emit_result() {
    cap_result_set product "$PRODUCT"
    cap_result_set productOrg "$PRODUCT_ORG"
    cap_result_set domain "$DOMAIN"
    cap_result_set engineRef "$RESOLVED_ENGINE_REF"
    cap_result_set registry "$REGISTRY_VALUE"
    cap_result_set productRoot "$ROOT"
    cap_result_set workspace "$PARENT"
    cap_result_set_raw skipClones "$( [[ -n "$SKIP_CLONES" ]] && echo true || echo false )"
    cap_result_set_raw dryRun "$( [[ -n "$DRY_RUN" ]] && echo true || echo false )"
}

function main() {
    cap_handle_meta "$@"
    reject_unknown_flags "$@"
    cap_parse_flags "$@"

    PRODUCT="$(cap_param product "")"
    PRODUCT_ORG="$(cap_param product-org "")"
    DOMAIN="$(cap_param domain "local.znas.io")"
    ENGINE_REF="$(cap_param engine-ref "")"
    REGISTRY_VALUE="$(cap_param registry "")"
    COCKPIT_REF="$(cap_param cockpit-ref "main")"
    SKIP_CLONES="$(cap_flag skip-clones)"
    DRY_RUN="$(cap_flag dry-run)"

    validate_params
    require_prerequisites
    RESOLVED_ENGINE_REF="$(resolve_engine_ref)"
    # Real registry when set; a fail-closed placeholder for local-only products
    # so staging/prod overlays still render a valid image ref (they also pin
    # all-zeros digests that fail closed until a real release).
    REGISTRY_MANIFEST="${REGISTRY_VALUE:-registry.example.com}"

    if [[ -n "$DRY_RUN" ]]; then
        print_dry_run_plan
        emit_result
        cap_ok
    fi

    write_product_env
    rename_token_paths
    substitute_tree
    replace_readme
    prune_template_artifacts
    clone_siblings

    cap_info "product '$PRODUCT' stamped. Next: review the diff, commit, then 'make up' (engine + cockpit siblings + docker/k3d required)."
    emit_result
    cap_ok
}

#=============================================================================
# ENTRY POINT
#=============================================================================

main "$@"
