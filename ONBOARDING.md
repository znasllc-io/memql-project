# Onboarding -- the __PRODUCT__ product

How this repo fits together, how it composes with the shared engine, and how to
make changes without breaking CI. __PRODUCT__ is a **single-repo memQL product**:
a DSL bundle + a client running on the product-agnostic
[memQL engine](https://github.com/znasllc-io/memql). No carrier repo, no product
`go.work`, no product Go in the common case.

## The workspace

Everything lives under a **parent directory** (the workspace). `scripts/init.sh`
clones the engine + cockpit as siblings of this repo:

```
<workspace>/
├── __PRODUCT__/          THIS repo -- the whole product (dsl/ + client/ + deploy/)
├── memql/                the shared engine (Go + MemQL DSL); product-agnostic, read-only for product work
└── memql-cockpit/        terminal-native IDE + ops console for clusters
```

| Repo | Remote | Role |
|---|---|---|
| `__PRODUCT__` | `__PRODUCT_ORG__/__PRODUCT__` | This product: DSL (`dsl/__PRODUCT__/`), client SPA (`client/`), deploy estate (`deploy/`). |
| `memql` | `znasllc-io/memql` | The engine: memory graph DB, AI, cluster nodes, the SDK generator + runtime core. Never edit it for product work. |
| `memql-cockpit` | `znasllc-io/memql-cockpit` | Terminal IDE / ops console; also the worker runtime. |

## How the product composes with the engine

Two mechanisms, both requiring **zero engine edits**:

1. **Runtime DSL delivery.** `deploy/Dockerfile.bundle` packages `dsl/` as a tiny
   data-only image. The vendored `deploy/k8s/components/dsl-bundle` kustomize
   component runs it as an init-container that copies the `.memql` tree into a
   shared volume the product's bff head reads at `MEMQL_DSL_PATH`. A plain engine
   `bff` image then loads the product DSL with no compiled-in product code
   (`dsl.MountRuntimeDomainsFromEnv`).
2. **Two ArgoCD Applications** (NOT a kustomize remote base -- ArgoCD's
   repo-server can't fetch a private cross-repo base with the Application's
   credential, and it would couple revisions). The **engine** Application
   (`memql-local`) owns the mesh; **this repo's** Application (`__PRODUCT__-local`)
   owns the bff head (`bff-__PRODUCT__`, labelled `memql/product-dsl=true`), the
   SPA, and the front door. The contract:
   `memql/docs/public/operate/downstream-stacks.md`.

## Local setup

Prerequisites: docker, k3d, kubectl, mkcert (`brew install k3d kubectl mkcert`),
Node >= 20, and the sibling `../memql` checkout (init.sh clones it).

```bash
# THE blessed run path: k3d + ArgoCD, staging parity.
make up          # engine bring-up + build/import the DSL bundle + SPA + register the product App
make dev         # rebuild the DSL bundle and re-mount it on the bff (inner loop)
make status      # product Application + mesh litmus (unique MEMQL_NODE_ID per pod)
make down        # tear down the whole cluster

# The SPA HMR inner loop (attached; localhost:8080, /memql proxied to the bff):
cd client && npm install && make dev
```

The front door serves `https://identity.__DOMAIN__`, `https://bff.__DOMAIN__`,
`https://app.__DOMAIN__` (portless TLS, mkcert wildcard). A private product repo
needs `MEMQL_K3D_REPO_TOKEN=$(gh auth token)` on `make up` so ArgoCD can read it.

**Extending the local lifecycle (`product.mk`).** The Makefile is byte-identical
across products, but it `-include`s an optional, product-OWNED `./product.mk` and
calls two no-op hooks -- `product-up` (during `make up`, after the SPA image is
imported and before the product Application is registered) and `product-dev`
(during `make dev`). A product with a genuinely product-specific LOCAL concern --
extra images to build+import (e.g. simulators standing in for external systems),
an extra local placement step -- adds it there with double-colon rules
(`product-up:: my-extra-images`). `product.mk` is git-tracked by the PRODUCT and
never template-synced, so it stays put across `git merge template/main`. Whether
the extras are scheduled is the LOCAL overlay's call, so staging/prod stay
fail-closed unless their overlays opt in. See the Makefile's "Product extension
hooks" section.

## The DSL (the whole product surface)

`dsl/__PRODUCT__/` holds `concepts` / `queries` / `mutations` / `shapes` /
`tools` / `automations` / `logic`. A **pure-DSL pack** (no product Go) can:

- model concepts (owned-tier authz via `ownerUserId`),
- write them (mutations) and read them (queries with filters/shapes/sort/paginate),
- react to graph events (automations firing logic/mutations),
- expose agent tools via `@handler(type="query", query="query|mutation ...")`.

The ONLY construct that needs Go is a builtin bound to
`@executor("integration.<name>.<cap>")` (an external call: HTTP, shell). The
starter deliberately avoids it -- if you need one, that is bespoke Go (a thin
`bff/` plugin), tracked in
[memql-project#11](https://github.com/znasllc-io/memql-project/issues/11).
Prefer DSL first.

**Validate a `.memql` tree locally** (no product Go needed, uses the sibling
engine clone):

```bash
cd ../memql && go run ./cmd/memqllint "$OLDPWD/dsl/__PRODUCT__"
```

This runs the engine's own load pipeline: parse + import-graph integrity for the
procedural kinds (query/mutation/logic/automation/spec/trait). It does NOT
resolve executor names or validate builtin/tool bodies -- a `make up` boot is the
full check.

## The SDK (client typing)

The production SDK is **`@__PRODUCT_ORG__/__PRODUCT__-sdk`** (GitHub Packages),
generated by the engine's `sdk-gen` over `core DSL ∪ dsl/__PRODUCT__/`. At stamp
time it does not exist, so the client shell is **self-contained**: a thin local
memQL client + a hand-seeded generated concepts module, so
`npm install && npm run build` pass immediately with no token. Wire the published
SDK later -- see `client/README.md` "SDK resolution".

## Change routing (the important part)

Before making a change, ask **"would a second product want this?"**

- **Yes** -> it belongs in the **template** (`znasllc-io/memql-project`) or the
  **engine** (`znasllc-io/memql`), not here. File it there; the engine is
  read-only for product work (a missing seam is an engine issue -- the template
  test gates every seam: "could a second product plug in without editing the
  engine?").
- **No (product-specific)** -> this repo.

## Staying in sync with the template

Operational files (Makefiles, `scripts/`, CI, `.gitignore`) are byte-identical to
the template and read `product.env`, so template improvements merge cleanly:

```bash
git remote add template https://github.com/znasllc-io/memql-project.git
git fetch template
git merge template/main --allow-unrelated-histories   # first time only
```

**Re-prune after the first sync.** `--allow-unrelated-histories` merges the
template's *pre-stamp* tree, which RESURRECTS everything `init.sh` renamed or
pruned: the template's **placeholder DSL directory** (the template ships `dsl/`
under its product-token name -- `git status` shows it next to your real
`dsl/__PRODUCT__/`), `.github/workflows/template-ci.yml`, `product.env.example`,
and the template's **placeholder ArgoCD app manifests** under
`deploy/argocd/apps/` (the two `*-staging.yaml` / `*-prod.yaml` files under the
token name, alongside your stamped `__PRODUCT__-staging.yaml` /
`__PRODUCT__-prod.yaml`). Delete the resurrected placeholders (keep your own
stamped paths) and commit:

```bash
git status                                     # lists the resurrected pre-stamp artifacts
git rm .github/workflows/template-ci.yml product.env.example
git rm -r <the resurrected placeholder DSL dir>          # NOT your dsl/__PRODUCT__/
git rm <the resurrected placeholder deploy/argocd/apps/*.yaml files>
git commit -m "chore: re-prune template artifacts after first template sync"
```

Runtime is safe even before you re-prune -- the engine skips `_`-prefixed DSL
domains, so the resurrected placeholder DSL dir never loads -- but leaving them
around is confusing. Later syncs are ordinary merges (no
`--allow-unrelated-histories`); expect **modify/delete conflicts** on those same
paths -- resolve them by keeping them deleted (`git rm` the path).

Product-owned files (DSL, manifests, docs, client source) are stamped and will
diverge -- that is expected; keep the plumbing byte-identical.

## Conventions

- **Branch / PR.** Feature branch -> PR -> merge -> delete branch -> pull main.
- **Stage by explicit path** (`git add <file>`), never `git add -A`.
- **Pre-1.0 everywhere.** No back-compat shims; when a contract changes, fix both
  sides at once and delete the old path.
- **Bare ids.** Clients use bare short slugs; canonicalization is server-side
  (`memql/docs/public/concepts/identifiers.md`). Never compose/parse/compare
  `v1:`-prefixed ids in client code.
- **No emojis** in code, comments, commit messages, or docs.

## Gotchas

- **The engine repo is read-only for product work.** A product need that seems to
  require an engine edit is a missing seam -- file an engine issue.
- **ArgoCD needs the branch PUSHED.** The local cluster's product Application
  tracks this repo by URL; ArgoCD cannot read local-only branches.
- **`make up` LB ports are fixed at cluster-create.** The first `make up` passes
  `EXTRA_PORTS`; changing them needs `make down` first.
- **DSL didn't update after an edit.** Re-run `make dev` -- it rebuilds the bundle
  image and rolls the deployments labelled `memql/product-dsl=true` so each
  init-container re-copies the tree.

## Where to dig deeper

- `CLAUDE.md` -- this repo's agent guide.
- `client/CLAUDE.md` -- SPA architecture + the bare-ids contract.
- `memql/docs/public/operate/downstream-stacks.md` -- the downstream contract.
- `memql/docs/public/build/building-a-pack.md` + `docs/public/language/authoring-rules.md`
  -- the DSL authoring contract.
