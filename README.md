# memql-project

GitHub **template for a memQL product**: one repo that becomes a whole product
running on the shared, product-agnostic
[memQL engine](https://github.com/znasllc-io/memql).

A product is a **DSL bundle plus one or more client surfaces** -- **no product
Go and no per-product node images** in the common case (platform consolidation,
[memql#2472](https://github.com/znasllc-io/memql/issues/2472)). You **Use this
template**, run `scripts/init.sh` once to stamp it in place, and you have a
product repo. The engine and cockpit are cloned as **siblings in the parent
directory** (the workspace); the composition at deploy time is **two ArgoCD
Applications** (engine + product), never a cross-repo kustomize base.

### `clients/` is plural

A client is anything a person or another system points at the cluster: a landing
page, an SPA, a mobile shell, a kiosk, a game. One operator serving one customer
routinely ships several, and a singular `client/` forced that into either a
second repo or a second build wedged into the first -- so every surface gets its
own directory under `clients/`.

The rule that keeps the plumbing from needing a per-product lookup: **a
surface's directory name is also its npm package name, its image name and its
k8s workload name.** `init.sh` stamps ONE surface (`clients/<product>-client/`)
and records it as `CLIENT` in `product.env`; you add more alongside it. The
engine repo carries exactly one inhabitant of its own `clients/` --
[`portal/`](https://github.com/znasllc-io/memql/blob/main/clients/README.md),
the platform's operations console -- which is the worked example this template
copies.

When a product genuinely needs one-of-a-kind Go that pure DSL and engine-generic
capabilities cannot express, the thin optional `bff/` escape hatch is **designed
but not implemented** (`init.sh` has no `--go-module` flag yet) --
[docs/design/bff-payload.md](docs/design/bff-payload.md) is the spec, and it is
built when a product first needs it. Exhaust DSL first.

```
<workspace>/                    the parent directory (created by init.sh clones)
├── <product>/                  THIS repo, stamped -- the whole product
│   ├── dsl/<product>/          the product DSL (.memql): the whole product surface
│   ├── clients/                the product's frontends -- PLURAL
│   │   ├── <product>-client/   the surface init.sh stamps (Vite + React + TS)
│   │   └── <product>-landing/  ...and any others the product needs
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
   renames `clients/__PRODUCT__-client/` -> `clients/acme-client/`;
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
   make up          # engine mesh + this product (bff + clients + DSL) on local k3d
   make dev         # rebuild the DSL bundle and re-mount it on the bff
   make status      # product Application + mesh status
   make down        # tear down
   cd clients/acme-client && make dev   # a surface's HMR inner loop (Vite on :8080)
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
| `__PRODUCT__` | product name (lowercase slug). Also names the DSL domain (`dsl/acme/`) and the stamped client surface (`clients/acme-client/`) | `acme` |
| `__PRODUCT_ORG__` | GitHub org/user owning the product repo | `acme-io` |
| `__DOMAIN__` | engine's fixed local domain (mkcert wildcard); also the staging/prod public-entry placeholder | `local.znas.io` |
| `__ENGINE_REF__` | engine ref pinned at stamp time (default: latest engine release tag, see below) | `0.12.1` |
| `__REGISTRY__` | container registry for the product images | `ghcr.io/acme-io` |

The engine org (`znasllc-io`) and the engine registry (`acrmemql.azurecr.io`)
stay literal. CI greps stamped output for leftover tokens (zero tolerance).

### The default engine ref is the latest release

`init.sh` pins `ENGINE_REF` to the **latest engine release tag**, resolved over
the network at stamp time (`resolve_latest_release_tag` reads
`git ls-remote --tags` of `znasllc-io/memql` and sorts on a `v`-stripped key, so
a bare `0.12.0` correctly wins over an older `v0.9.6`). The first release that
carries the downstream contract this template needs -- `scripts/k3d/import-image.sh`,
the k3d `up.sh` interface, and the current DSL grammar
([`downstream-stacks.md`](https://github.com/znasllc-io/memql/blob/main/docs/public/operate/downstream-stacks.md)
`sinceVersion 0.12.0`) -- is `0.12.0`, so a default stamp today pins `0.12.0`.

- Pass `--engine-ref=<tag>` to pin a specific ref instead.
- Offline, resolution falls back to `main` with a loud warning; the stamp then
  tracks engine `main` rather than a pinned release, so re-run with
  `--engine-ref=<tag>` once online to pin one.
- **To bump an already-stamped product:** edit `ENGINE_REF` in `product.env`
  **and** the engine image pins under `deploy/k8s/overlays/*`, then re-run CI. A
  flagless `init.sh` re-run preserves the existing pin -- it never re-resolves.

(History: the default was temporarily `main` while the engine shipped no
consolidation release -- engine release gap
[znasllc-io/memql#2510](https://github.com/znasllc-io/memql/issues/2510),
flip-back [znasllc-io/memql-project#14](https://github.com/znasllc-io/memql-project/issues/14).)

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
`clients/__PRODUCT__-client/`, `template-ci.yml`, `product.env.example`,
`deploy/argocd/apps/__PRODUCT__-*.yaml`).
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
| `clients/` | the product's client surfaces -- PLURAL, one directory per surface |
| `clients/__PRODUCT__-client/` | the one surface the template ships: a self-contained SPA shell (builds at stamp time) |
| `deploy/` | bundle image + kustomize overlays + ArgoCD manifests |
| `ONBOARDING.md` / `CLAUDE.md` | dev guide + agent guide the stamp personalizes |
| `.github/workflows/` | `template-ci.yml` (template-only), `ci.yml` (product CI), `gitleaks.yml` |

### Adding a second client surface

`clients/` is plural, so a second surface is additive -- nothing about the first
one changes:

1. `clients/<product>-landing/` with a `package.json` whose `name` is
   `<product>-landing`, its own `Dockerfile`, and (copy the stamped surface's)
   `Makefile` + `scripts/dev/build-image.sh`. Those two are name-agnostic: they
   derive the image and workload name from their own directory.
2. A Deployment + Service in `deploy/k8s/base/` (copy `app.yaml`, rename), an
   `images:` entry per overlay, and a front-door / public-entry route.
3. Build + import it locally by extending the root Makefile's `product-up` hook
   from your own `product.mk`:

   ```makefile
   product-up:: landing-image                       # in ./product.mk
   landing-image:
   	$(MAKE) -C clients/$(PRODUCT)-landing image CLUSTER=$(CLUSTER)
   ```

CI needs no edit: the `clients` lane, the shellcheck sweep and the staging/prod
digest gate all enumerate rather than name a directory. The **release lockfile**
does: `deploy/releases/<id>.yaml` pins one `client` component (the surface
`CLIENT` names), so a second surface's digest is pinned by hand until the
lockfile shape grows a component per surface -- see
[deploy/releases/README.md](deploy/releases/README.md).

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
