# __PRODUCT__ -- DSL-first memQL product

**Type:** DSL bundle + client (no product Go in the common case)
**Runs on:** the shared, product-agnostic memQL engine (github.com/znasllc-io/memql)

This repo is the WHOLE product surface expressed as DSL. There is no carrier,
no go.work, no Go module unless the product invents bespoke Go (then a thin
`bff/` plugin appears -- prefer DSL first).

## Layout
- `dsl/__PRODUCT__/` -- concepts, queries, mutations, shapes, specs, tools,
  prompts, automations. Reusable capabilities (chat/daily-space/avatar/...) are
  generic engine features you reference via `integration.<name>.*` -- zero Go.
- `Dockerfile` -- packages `dsl/` as a tiny data-only bundle image; the engine's
  `dsl-bundle` component mounts it at runtime (MEMQL_DSL_PATH).
- `deploy/k8s/overlays/<env>/` -- ONE overlay = engine base + dsl-bundle
  component + {engine version, bundle digest, client digest} pins.

## Authoring
Edit `.memql` files under `dsl/__PRODUCT__/`. See the engine's
`docs/public/language/authoring-rules.md` and the `MEMQL_DSL_PATH` section in
the engine CLAUDE.md. A restart with the bundle re-mounted picks up changes;
no rebuild of any Go binary.
