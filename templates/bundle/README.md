# __PRODUCT__

A **memQL product** — a DSL bundle + a client, running on the shared,
product-agnostic [memQL engine](https://github.com/znasllc-io/memql). There is
**no product Go and no per-product node images** in the common case
(platform consolidation, [memql#2472](https://github.com/znasllc-io/memql/issues/2472)).

```
__PRODUCT__/                     this repo (DSL-first; no go.work, no Go module)
├── dsl/__PRODUCT__/             the product DSL tree (.memql) -- the whole product surface
├── Dockerfile                   builds the tiny data-only DSL-bundle image (busybox + dsl)
├── client/                      the product frontend (SPA)   ← added by Step-5 consolidation
└── deploy/k8s/overlays/<env>/   ONE overlay: engine base + dsl-bundle component + {engine,bundle,client} pins
```

## How it runs

The engine ships every node type (identity / bff / cognition / agent / planner
/ voice / workbench / mcp) as a **product-agnostic image**. This product's DSL
is delivered to those nodes **at runtime**: `Dockerfile` packages `dsl/` as a
tiny data-only image; the engine's `dsl-bundle` kustomize component runs it as
an init-container that copies the tree into a shared volume the mesh nodes read
at `MEMQL_DSL_PATH` (`dsl.MountRuntimeDomainsFromEnv`). A "bff" is just a plain
engine `bff` node fronting this product's bundle — a deploy concern, not code.

A **release is `{engine version, bundle digest, client digest}`** pinned in one
overlay in this one repo — no carrier repo, no coherence check, no lockfile
fleet.

## Extending the product

Everything is DSL (`dsl/__PRODUCT__/*.memql`): concepts, queries, mutations,
shapes, specs, tools, prompts, automations. Reusable capabilities (chat,
daily-space, avatar, …) live in the engine as generic features you configure
from DSL — you reference `integration.<name>.*` with zero product Go. Only
genuinely one-of-a-kind Go warrants a thin optional `bff/` plugin module (and
only then does this repo gain a `go.mod` + the engine dependency).

## Bespoke Go (rare)

If the product needs bespoke Go the engine can't provide generically, stamp the
`carrier` variant instead of `bundle` (`--go-module`) — it carries a thin
`bff/` module + a `go.work`. Prefer DSL first.
