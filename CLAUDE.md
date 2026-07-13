# __PRODUCT__ -- DSL-first memQL product (agent guide)

**Type:** a single-repo memQL product = a DSL bundle + a client (no product Go
in the common case).
**Runs on:** the shared, product-agnostic memQL engine
(github.com/znasllc-io/memql), composed at deploy time as TWO ArgoCD
Applications (engine + this product).

This ONE repo is the whole product surface. It was stamped from the
[memql-project](https://github.com/znasllc-io/memql-project) template by
`scripts/init.sh`; there is no carrier repo, no product `go.work`, no product Go
module unless the product later invents bespoke Go (a thin `bff/` plugin --
tracked in memql-project#11; prefer DSL first).

## Layout

- `dsl/__PRODUCT__/` -- the product DSL (.memql): `concepts`, `queries`,
  `mutations`, `shapes`, `tools`, `automations`, `logic`. The whole product
  surface. Reusable capabilities (chat/daily-space/avatar/...) are generic
  engine features you reference from DSL; only genuinely one-of-a-kind Go
  warrants a `bff/` plugin.
- `client/` -- the product frontend (Vite + React + TS SPA). Bare-ids contract
  enforced by ESLint. See `client/CLAUDE.md`.
- `deploy/` -- `Dockerfile.bundle` (the data-only DSL-bundle image) +
  `k8s/{base,components/dsl-bundle,overlays/{local,staging,prod}}` +
  `argocd/` (the product AppProject + staging/prod Applications).
- `product.env` -- product identity (PRODUCT, PRODUCT_ORG, DOMAIN, ENGINE_REF,
  REGISTRY). Every operational file reads it.
- `Makefile` -- the local stack lifecycle (`make up|dev|status|down`).

## How it runs (the delivery mechanism)

The engine ships every node type as a **product-agnostic image**. This product's
DSL reaches the engine **at runtime**: `deploy/Dockerfile.bundle` packages
`dsl/` as a tiny data-only image; the vendored `deploy/k8s/components/dsl-bundle`
kustomize component runs it as an init-container that copies the tree into a
shared volume the product's bff head reads at `MEMQL_DSL_PATH`
(`dsl.MountRuntimeDomainsFromEnv`). The product's bff (`bff-__PRODUCT__`,
labelled `memql/product-dsl=true`) is a plain engine `bff` node -- a deploy
concern, not code.

Composition is TWO ArgoCD Applications (never a kustomize remote base): the
engine Application owns the mesh; this repo's `<product>-local` Application owns
the bff head + SPA + front door + DSL bundle. See
`../memql/docs/public/operate/downstream-stacks.md`.

## Authoring DSL

Edit `.memql` files under `dsl/__PRODUCT__/`. A pure-DSL pack can model concepts,
read/write them (queries/mutations), react to graph events (automations calling
logic/mutations), and expose agent tools -- all with ZERO product Go. The
`@executor("integration.<name>.*")` builtin is the ONLY construct that needs Go
(a bff plugin); the starter deliberately avoids it. See the engine's
`docs/public/language/authoring-rules.md` and `docs/public/build/building-a-pack.md`.
Validate locally: `cd ../memql && go run ./cmd/memqllint <abs-path>/dsl/__PRODUCT__`
(parse + import-graph integrity). A `make dev` re-mounts the bundle; no Go
rebuild.

## Conventions

- **Bare ids.** Clients use bare short slugs; canonicalization is server-side.
  Never compose/parse/compare `v1:`-prefixed ids in client code.
- **No emojis** in code, comments, commits, or docs.
- **Change routing.** "Would a second product want this?" -> it belongs in the
  template or the engine, not here. Product-specific -> this repo. The engine is
  read-only for product work (a missing seam is an engine issue).
- **Template sync.** Operational files (Makefiles, scripts, CI) are
  byte-identical to the template and read `product.env`, so
  `git merge template/main` stays clean. Keep them that way.
