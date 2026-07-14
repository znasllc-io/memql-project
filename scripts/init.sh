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
cap_spec_param "domain"       "the engine's fixed local domain (leave default for local; it is also the staging/prod public-entry placeholder) (default: local.znas.io)"
cap_spec_param "engine-ref"   "engine ref to pin (default: main, until a >=0.12.0 engine release ships the downstream contract -- znasllc-io/memql#2510, flip-back memql-project#14)"
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

# Default engine ref when --engine-ref is not passed. Deliberately the literal
# "main", NOT the latest release tag: NO tagged engine release yet carries the
# downstream contract this template needs. downstream-stacks.md declares
# sinceVersion 0.12.0, but the latest tag is 0.11.2 -- which lacks
# scripts/k3d/import-image.sh AND parses a mutually-exclusive DSL grammar, so a
# tag-pinned stamp lints green yet cannot `make up`. Pinning main gives a stamp
# whose grammar + k3d layout match the code the template targets. Flip this back
# to resolve_latest_release_tag once a >=0.12.0 engine release exists.
#   engine release gap:  znasllc-io/memql#2510
#   flip-back tracking:  znasllc-io/memql-project#14
DEFAULT_ENGINE_REF="main"

# Unknown-flag allowlist. The vendored capability.sh cap_parse_flags accepts ANY
# --flag (it only rejects positionals); this script enforces its own surface so
# a typo'd flag fails loudly (exit 2) instead of being silently ignored. Upstream
# fix -- making cap_parse_flags reject unknown flags against the declared spec --
# is tracked in znasllc-io/memql#2508; drop this local check when it lands.
CAP_KNOWN_FLAGS=" product product-org domain engine-ref registry cockpit-ref skip-clones dry-run help print-spec params-stdin "

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

# Template-owned paths substitute_tree is ALLOWED to stamp (an allowlist, walked
# instead of the whole repo root). A product repo can carry non-template content
# of its own whose files may contain token-like literals; walking only these
# paths guarantees such content is never silently rewritten. is_skipped still
# applies WITHIN them (e.g. it keeps
# client/scripts/, client/Makefile, client/.gitignore byte-identical). Paths are
# relative to ROOT; a directory is stamped recursively, a bare file on its own.
# This list must stay in sync with print_dry_run_plan's "would stamp:" line and
# with rename_token_paths (dsl/, deploy/ hold the token-bearing renamed paths).
CAP_STAMP_PATHS=(
    "dsl"
    "client"
    "deploy"
    "ONBOARDING.md"
    "CLAUDE.md"
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

# validate_substitution_values -- the free-form values that flow UNQUOTED into
# the sed token program + file contents (domain, engine-ref, registry) must not
# carry sed metacharacters or whitespace. Left unvalidated, `&` in a value is
# taken by sed as "the matched text" (so --engine-ref='feat/x&y' silently
# corrupts every overlay), and `|` collides with the sed delimiter (so
# --domain='a|b' aborts mid-stamp) -- C1. Reject with exit 2 BEFORE any mutation.
# Allowlists (not denylists) so anything sed- or shell-dangerous is refused:
#   domain     hostname chars                         [A-Za-z0-9.-]
#   engine-ref git ref chars (slashes ok, no &|\ ws)  [A-Za-z0-9._/-]
#   registry   host[:port][/path] chars               [A-Za-z0-9._:/-]
function validate_substitution_values() {
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] \
        || cap_fail 2 "invalid --domain '$DOMAIN' (want a hostname: ^[A-Za-z0-9.-]+$; no whitespace or sed metacharacters)"
    if [[ -n "$ENGINE_REF" ]]; then
        [[ "$ENGINE_REF" =~ ^[A-Za-z0-9._/-]+$ ]] \
            || cap_fail 2 "invalid --engine-ref '$ENGINE_REF' (want a git ref: ^[A-Za-z0-9._/-]+$; no whitespace or sed metacharacters)"
    fi
    if [[ -n "$REGISTRY_VALUE" ]]; then
        [[ "$REGISTRY_VALUE" =~ ^[A-Za-z0-9._:/-]+$ ]] \
            || cap_fail 2 "invalid --registry '$REGISTRY_VALUE' (want host[:port][/path]: ^[A-Za-z0-9._:/-]+$; no whitespace or sed metacharacters)"
    fi
    return 0
}

# read_existing_env -- parse an already-written product.env into the EXISTING_*
# globals (empty when the file is absent). Line-parsed (not sourced) so a stray
# shell metacharacter in a hand-edited value can never execute. Underpins the
# re-run identity guard + value preservation (B1).
function read_existing_env() {
    EXISTING_PRODUCT=""; EXISTING_ORG=""; EXISTING_DOMAIN=""
    EXISTING_ENGINE_REF=""; EXISTING_REGISTRY=""; EXISTING_REGISTRY_SET=0
    local f="$ROOT/product.env" line k v
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|\#*) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            PRODUCT)     EXISTING_PRODUCT="$v" ;;
            PRODUCT_ORG) EXISTING_ORG="$v" ;;
            DOMAIN)      EXISTING_DOMAIN="$v" ;;
            ENGINE_REF)  EXISTING_ENGINE_REF="$v" ;;
            REGISTRY)    EXISTING_REGISTRY="$v"; EXISTING_REGISTRY_SET=1 ;;
        esac
    done < "$f"
    return 0
}

# reconcile_with_existing_env -- on a re-run (product.env present):
#   1. REFUSE (exit 3, no mutation) when the requested identity (product/org)
#      disagrees with the stamped one -- a token-keyed re-stamp would half-apply
#      and lie (the tree keeps the old dsl/<product>/ + manifests while
#      product.env + the envelope claim the new name). B1.
#   2. PRESERVE hand-edited/pinned values: for domain/engine-ref/registry, keep
#      the value already in product.env UNLESS the corresponding flag was passed
#      explicitly this run -- so a flagless re-run never re-resolves ENGINE_REF
#      over the network and rewrites the pin out from under the stamped overlays.
function reconcile_with_existing_env() {
    [[ -f "$ROOT/product.env" ]] || return 0
    read_existing_env
    if { [[ -n "$EXISTING_PRODUCT" ]] && [[ "$EXISTING_PRODUCT" != "$PRODUCT" ]]; } \
       || { [[ -n "$EXISTING_ORG" ]] && [[ "$EXISTING_ORG" != "$PRODUCT_ORG" ]]; }; then
        cap_fail 3 "product.env is already stamped as '${EXISTING_PRODUCT}/${EXISTING_ORG}'; refusing to re-stamp as '${PRODUCT}/${PRODUCT_ORG}' (a different identity) -- a token-keyed re-run would half-apply and leave the tree inconsistent. Re-run with the original identity, or start from a fresh template checkout."
    fi
    if [[ -n "$ENGINE_REF_FLAG" && -n "$EXISTING_ENGINE_REF" && "$ENGINE_REF" != "$EXISTING_ENGINE_REF" ]]; then
        cap_warn "--engine-ref '$ENGINE_REF' differs from the stamped ENGINE_REF '$EXISTING_ENGINE_REF'. The overlays already CONSUMED the old ref (the __ENGINE_REF__ tokens are gone), so the new ref lands in product.env ONLY -- the stamped manifests keep '$EXISTING_ENGINE_REF'. Re-stamp from a fresh template copy if you need the overlays repinned."
    fi
    [[ -z "$DOMAIN_FLAG"     && -n "$EXISTING_DOMAIN"     ]] && DOMAIN="$EXISTING_DOMAIN"
    [[ -z "$ENGINE_REF_FLAG" && -n "$EXISTING_ENGINE_REF" ]] && ENGINE_REF="$EXISTING_ENGINE_REF"
    [[ -z "$REGISTRY_FLAG"   && "$EXISTING_REGISTRY_SET" == "1" ]] && REGISTRY_VALUE="$EXISTING_REGISTRY"
    return 0
}

# detect_orphaned_stamp -- refuse (exit 3) when product.env is ABSENT but the
# tree already shows stamp evidence (someone deleted product.env on an
# already-stamped repo). Without this, a fresh stamp with a NEW identity
# half-applies: the token-bearing paths were already renamed/substituted away, so
# the run writes a product.env + envelope claiming the new name over a tree that
# still carries the old one -- and reports ok:true (the B1-adjacent hole). Stamp
# evidence = init.sh's own irreversible first-stamp effects: the pre-stamp DSL dir
# `dsl/__PRODUCT__/` was renamed away, or `template-ci.yml` was pruned. A pristine
# template checkout has BOTH, so a legitimate first stamp is never blocked.
function detect_orphaned_stamp() {
    [[ -f "$ROOT/product.env" ]] && return 0     # present -> reconcile_with_existing_env owns it
    if [[ ! -d "$ROOT/dsl/__PRODUCT__" ]] || [[ ! -e "$ROOT/.github/workflows/template-ci.yml" ]]; then
        cap_fail 3 "product.env is missing but this tree was already stamped (dsl/__PRODUCT__/ was renamed away, or template-ci.yml was pruned) -- refusing to stamp over it with a new identity. Restore product.env (e.g. 'git checkout -- product.env' or from history), or start from a fresh template checkout."
    fi
    return 0
}

# resolve_latest_release_tag -> the newest engine RELEASE tag (or "" if none).
# RETAINED for the flip-back to a tag default (memql-project#14) once a >=0.12.0
# engine release ships the downstream contract; it is NOT called while the
# default is main (see DEFAULT_ENGINE_REF). The engine tag set MIXES v-prefixed
# ('v0.9.6') and bare ('0.11.2') tags; a naive `sort -V` sorts every 'v...'
# string AFTER every bare-numeric one, so the newest bare release loses to a far
# older v-tag. Sort on a v-STRIPPED key (field 1) while keeping the ORIGINAL tag
# string (field 2) for the pin (the B3a fix, kept live for the flip).
function resolve_latest_release_tag() {
    git ls-remote --tags --refs "$ENGINE_REPO" 2>/dev/null \
        | awk -F/ '{print $NF}' \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
        | awk '{orig=$0; norm=$0; sub(/^v/,"",norm); print norm"\t"orig}' \
        | sort -V -k1,1 \
        | tail -1 \
        | cut -f2 || true
}

# resolve_engine_ref -> echoes the ref to pin. Explicit --engine-ref wins; else
# the default (currently DEFAULT_ENGINE_REF="main"; see its note + #2510/#14).
# FLIP for #14: replace the default line with
#   local latest; latest="$(resolve_latest_release_tag)"; printf '%s' "${latest:-main}"
# once a >=0.12.0 engine release exists.
function resolve_engine_ref() {
    if [[ -n "$ENGINE_REF" ]]; then printf '%s' "$ENGINE_REF"; return; fi
    printf '%s' "$DEFAULT_ENGINE_REF"
}

# PRODUCT_ID -- an identifier-safe form of the product name (hyphens -> under-
# scores) for positions that must be a valid JS/TS/Go identifier, e.g. the
# generated concepts.ts object KEYS (demo-app_GREETING is a syntax error; the
# `v1:demo-app:greeting` string VALUE is fine and keeps __PRODUCT__). Non-
# hyphenated names are unchanged, so this is a no-op for the common case (B5).
PRODUCT_ID=""   # set in main() once PRODUCT is known

# substitute_tokens_in_string <string> -- for path renames.
function substitute_tokens_in_string() {
    local s="$1"
    s="${s//__PRODUCT_ID__/$PRODUCT_ID}"
    s="${s//__PRODUCT_ORG__/$PRODUCT_ORG}"
    s="${s//__PRODUCT__/$PRODUCT}"
    s="${s//__DOMAIN__/$DOMAIN}"
    s="${s//__ENGINE_REF__/$RESOLVED_ENGINE_REF}"
    s="${s//__REGISTRY__/$REGISTRY_VALUE}"
    printf '%s' "$s"
}

# sed_token_program -- the shared sed expression list (used for file contents).
# __PRODUCT_ID__ is substituted first (longest, non-overlapping with __PRODUCT__).
# __REGISTRY__ uses REGISTRY_MANIFEST, which is the real registry when set and a
# fail-closed placeholder (registry.example.com) when local-only, so the
# staging/prod overlays always render a VALID image ref (no leading-slash name)
# even though product.env REGISTRY stays empty for a local-only product.
function sed_token_program() {
    printf 's|__PRODUCT_ID__|%s|g; s|__PRODUCT_ORG__|%s|g; s|__PRODUCT__|%s|g; s|__DOMAIN__|%s|g; s|__ENGINE_REF__|%s|g; s|__REGISTRY__|%s|g' \
        "$PRODUCT_ID" "$PRODUCT_ORG" "$PRODUCT" "$DOMAIN" "$RESOLVED_ENGINE_REF" "$REGISTRY_MANIFEST"
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
# SCOPE: walks ONLY the template-owned CAP_STAMP_PATHS, never the whole repo root,
# so a product repo's own content (its app, design assets) keeps any __TOKEN__-
# looking literals verbatim. is_skipped still runs as a secondary guard for the
# operational files nested inside those paths (e.g. client/scripts/).
function substitute_tree() {
    local prog rel tmp p roots=()
    prog="$(sed_token_program)"
    for p in "${CAP_STAMP_PATHS[@]}"; do
        [[ -e "$ROOT/$p" ]] && roots+=("$ROOT/$p")
    done
    if [[ ${#roots[@]} -eq 0 ]]; then
        cap_step "no template-owned paths present to substitute"
        return 0
    fi
    # -print0/read -d '' keeps paths with spaces safe; bash 3.2 compatible.
    while IFS= read -r -d '' f; do
        rel="${f#"$ROOT"/}"
        is_skipped "$rel" && continue
        grep -q '__PRODUCT_ID__\|__PRODUCT__\|__PRODUCT_ORG__\|__DOMAIN__\|__ENGINE_REF__\|__REGISTRY__' "$f" 2>/dev/null || continue
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
    done < <(find "${roots[@]}" -type f -not -path '*/.git/*' -print0)
    cap_step "substituted tokens across template-owned paths"
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
        printf 'The first `--allow-unrelated-histories` merge pulls the template'"'"'s\n'
        printf 'PRE-STAMP tree, so it resurrects what init.sh pruned/renamed: the\n'
        printf 'template placeholder DSL directory (next to your `dsl/%s/`),\n' "$PRODUCT"
        printf '`template-ci.yml`, `product.env.example`, and the placeholder ArgoCD\n'
        printf 'app files under `deploy/argocd/apps/`. Re-prune and commit them after\n'
        printf 'the first sync (runtime is safe meanwhile -- the engine skips\n'
        printf '`_`-prefixed DSL domains); later syncs are ordinary merges with\n'
        printf 'modify/delete conflicts on those paths -- keep them deleted. See\n'
        printf '`ONBOARDING.md` for the exact commands.\n\n'
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

    # Was the flag passed explicitly this run? (empty = not passed) -- drives the
    # B1 value-preservation rule (preserve product.env's value unless overridden).
    DOMAIN_FLAG="$(cap_flag domain)"
    ENGINE_REF_FLAG="$(cap_flag engine-ref)"
    REGISTRY_FLAG="$(cap_flag registry)"

    validate_params
    require_prerequisites
    # Guard the re-run cases BEFORE resolving/validating/mutating (all exit 3, no
    # mutation): (1) product.env deleted on an already-stamped tree, and (2)
    # product.env present but the requested identity disagrees. Reconcile also
    # preserves pinned values so a flagless re-run is a true no-op (B1); it must
    # precede resolve_engine_ref so a preserved ref is not re-resolved.
    detect_orphaned_stamp
    reconcile_with_existing_env
    validate_substitution_values
    PRODUCT_ID="${PRODUCT//-/_}"     # identifier-safe form for JS/TS/Go id positions (B5)
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
