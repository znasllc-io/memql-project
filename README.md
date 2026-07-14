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

When a product genuinely needs one-of-a-kind Go that pure DSL and engine-generic
capabilities cannot express, the thin optional `bff/` escape hatch
(`init.sh --go-module`) is designed in
[docs/design/bff-payload.md](docs/design/bff-payload.md) -- exhaust DSL first.

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

   Leave `--domain` at its default: the local stack's identity, front door,
   mkcert cert, and token issuer are all **engine-owned and fixed at the
   engine's local domain** (`local.znas.io`), so a custom local domain has
   nothing serving `identity.<domain>` (magic-link login impossible, TLS
   mismatched, the bff rejects every token). `DOMAIN` matters for the
   **staging/prod public entries**, which you set on the overlays at activation
   time (see each overlay's activation checklist) -- not per local stamp.

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
| `__DOMAIN__` | engine's fixed local domain (mkcert wildcard); also the staging/prod public-entry placeholder | `local.znas.io` |
| `__ENGINE_REF__` | engine ref pinned at stamp time (default `main`, see below) | `main` |
| `__REGISTRY__` | container registry for the product images | `ghcr.io/acme-io` |

The engine org (`znasllc-io`) and the engine registry (`acrmemql.azurecr.io`)
stay literal. CI greps stamped output for leftover tokens (zero tolerance).

### Why the default engine ref is `main` (temporary)

`init.sh` pins `ENGINE_REF=main` by default rather than the latest release tag.
No tagged engine release yet carries the downstream contract this template needs:
[`downstream-stacks.md`](https://github.com/znasllc-io/memql/blob/main/docs/public/operate/downstream-stacks.md)
declares `sinceVersion 0.12.0`, but the newest tag is `0.11.2`, which lacks
`scripts/k3d/import-image.sh` **and** parses a DSL grammar mutually exclusive with
`main`'s -- so a tag-pinned stamp lints green yet cannot `make up`. Pinning `main`
gives a stamp whose grammar + k3d layout match the code the template targets. The
fixed latest-release-tag resolver is retained in `init.sh` for the flip-back once
a `>=0.12.0` engine release exists: engine release gap
[znasllc-io/memql#2510](https://github.com/znasllc-io/memql/issues/2510),
flip-back [znasllc-io/memql-project#14](https://github.com/znasllc-io/memql-project/issues/14).
Pass `--engine-ref=<tag>` to pin a specific ref regardless.

### ArgoCD repo-URL naming invariant

The staging/prod ArgoCD manifests (`deploy/argocd/apps/*` + `project.yaml`) bake
`https://github.com/<product-org>/<product>.git` -- i.e. they assume your GitHub
repo is named **exactly `<product>`**. The local `make up` sidesteps this by
deriving the repo URL from your `origin` remote, but the committed ArgoCD
manifests cannot. If your repo has a different name, fix `repoURL` in both app
files and the project `sourceRepos` before activating staging/prod (called out in
each overlay's activation checklist).

## Staying in sync with the template (for stamped products)

Operational files are byte-identical to this template, so improvements merge
cleanly:

```bash
git remote add template https://github.com/znasllc-io/memql-project.git
git fetch template
git merge template/main --allow-unrelated-histories   # first time only
```

The first `--allow-unrelated-histories` merge pulls the template's **pre-stamp**
tree, so it resurrects what `init.sh` pruned/renamed (`dsl/__PRODUCT__/`,
`template-ci.yml`, `product.env.example`, `deploy/argocd/apps/__PRODUCT__-*.yaml`).
Re-prune them and commit after the first sync (runtime is safe meanwhile -- the
engine skips `_`-prefixed DSL domains). Later syncs are ordinary merges; expect
modify/delete conflicts on those paths and resolve by keeping them deleted. See
`ONBOARDING.md` "Staying in sync with the template" for the exact commands.

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

### Running two products locally

All local products share the engine's fixed local domain (`local.znas.io`) --
identity/TLS/issuer are engine-owned, so a per-product `--domain` is **not** the
isolation knob (a custom local domain breaks login, see the Quickstart note).
Isolate by cluster + Application instead, not by domain:

- Run one local stack at a time (simplest): `make down` one, `make up` the next.
- Or give each its own k3d cluster and LB ports: `make up CLUSTER=acme
  EXTRA_PORTS=50051:50051` for one, `make up CLUSTER=beta EXTRA_PORTS=50052:50051`
  for the other. Each product registers its own ArgoCD Application
  (`<product>-local`), and `CLUSTER`/`EXTRA_PORTS` keep the two stacks on
  separate clusters and host ports -- same local domain, no collision.
