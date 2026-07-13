# memql-project

GitHub **template for a memQL product**: one repo that becomes a whole product
running on the shared, product-agnostic
[memQL engine](https://github.com/znasllc-io/memql).

A product is a **DSL bundle + a client** -- **no product Go and no per-product
node images** in the common case (platform consolidation,
[memql#2472](https://github.com/znasllc-io/memql/issues/2472)). You **Use this
template**, run `scripts/init.sh` once to stamp it in place, and you have a
product repo. The engine and cockpit are cloned as **siblings in the parent
directory** (the workspace); the composition at deploy time is **two ArgoCD
Applications** (engine + product), never a cross-repo kustomize base.

```
<workspace>/                    the parent directory (created by init.sh clones)
├── <product>/                  THIS repo, stamped -- the whole product
│   ├── dsl/<product>/          the product DSL (.memql): the whole product surface
│   ├── client/                 the product frontend (SPA)
│   ├── deploy/                 DSL-bundle image + kustomize overlays + ArgoCD manifests
│   ├── product.env             product identity every operational file reads
│   └── Makefile                local stack lifecycle (make up|dev|status|down)
├── memql/                      the shared engine (cloned; never edited per-product)
└── memql-cockpit/              terminal IDE / ops console (cloned)
```

The engine never names a product; products plug in through the documented seams
(`memql/docs/public/operate/downstream-stacks.md` and the `MEMQL_DSL_PATH`
runtime-delivery mechanism). The acceptance bar for the whole pattern: **a second
product boots a full stack with zero engine-repo edits.**

## Quickstart

1. Click **Use this template** to create your product repo, then clone it.
2. Stamp it in place (non-interactive capability script; `--help` for all params):

   ```bash
   scripts/init.sh --product=acme --product-org=acme-io
   ```

   This writes `product.env`; renames `dsl/__PRODUCT__/` -> `dsl/acme/`;
   substitutes the tokens below only where a tool cannot read `product.env` at
   runtime (DSL contents, k8s/ArgoCD manifest fields, the client package +
   boot defaults, `ONBOARDING.md`, `CLAUDE.md`); clones `../memql` and
   `../memql-cockpit` as siblings; and prunes the template-only artifacts
   (`template-ci.yml`, `product.env.example`) plus this README (replaced with a
   product stub). Pass `--registry=...` for a real image registry (default:
   empty = local-only), `--engine-ref=...` to pin the engine, `--skip-clones`
   to skip the sibling clones, `--dry-run` to preview with zero mutation.

3. Bring up the stack (requires docker, k3d, kubectl, mkcert, and the sibling
   `../memql`):

   ```bash
   make up          # engine mesh + this product (bff + SPA + DSL) on local k3d
   make dev         # rebuild the DSL bundle and re-mount it on the bff
   make status      # product Application + mesh status
   make down        # tear down
   cd client && make dev   # the SPA HMR inner loop (Vite on :8080)
   ```

   The front door serves `https://identity.<domain>`, `https://bff.<domain>`,
   and `https://app.<domain>`.

4. Read the stamped `ONBOARDING.md` for the development workflow and `CLAUDE.md`
   for the repo agent guide.

## Template tokens

`scripts/init.sh` substitutes these in file contents and file/directory names,
**only where unavoidable** (a tool genuinely cannot read `product.env` there).
Operational files (Makefiles, `scripts/`, CI, `.gitignore`) contain **no tokens**
and read `product.env` instead, so a later `git merge template/main` never
conflicts on plumbing.

| Token | Meaning | Example |
|---|---|---|
| `__PRODUCT__` | product name (lowercase slug) | `acme` |
| `__PRODUCT_ORG__` | GitHub org/user owning the product repo | `acme-io` |
| `__DOMAIN__` | local front-door domain (mkcert wildcard) | `local.znas.io` |
| `__ENGINE_REF__` | engine ref pinned at stamp time | `v0.12.4` |
| `__REGISTRY__` | container registry for the product images | `ghcr.io/acme-io` |

The engine org (`znasllc-io`) and the engine registry (`acrmemql.azurecr.io`)
stay literal. CI greps stamped output for leftover tokens (zero tolerance).

## Staying in sync with the template (for stamped products)

Operational files are byte-identical to this template, so improvements merge
cleanly:

```bash
git remote add template https://github.com/znasllc-io/memql-project.git
git fetch template
git merge template/main --allow-unrelated-histories   # first time only
```

Route changes by asking "would a second product want this?" -> the template or
the engine; product-specific -> the product repo.

## Repository layout (pre-stamp)

| Path | Purpose |
|---|---|
| `scripts/init.sh` | the in-place stamper -- a capability script (JSON on stdout, honest exit codes) |
| `scripts/lib/capability.sh` | vendored capability-script runtime from the engine |
| `product.env.example` | the product-identity template (pruned by init) |
| `dsl/__PRODUCT__/` | the starter DSL pack (pure DSL; loads + runs on a plain engine) |
| `client/` | the client SPA shell (self-contained; builds at stamp time) |
| `deploy/` | bundle image + kustomize overlays + ArgoCD manifests |
| `ONBOARDING.md` / `CLAUDE.md` | dev guide + agent guide the stamp personalizes |
| `.github/workflows/` | `template-ci.yml` (template-only), `ci.yml` (product CI), `gitleaks.yml` |

Note: two stamped products default to the same `__DOMAIN__` front-door
hostnames, so run one local stack at a time or stamp each with its own
`--domain`.
