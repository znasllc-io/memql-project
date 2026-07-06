# memql-bff-__PRODUCT__

__PRODUCT__ backend-for-frontend layer over memQL. Carries the
__PRODUCT__-specific DSL (concepts, mutations, queries, shapes, tools,
prompts, automations, builtins) and the Go plug-in code that
registers __PRODUCT__ routing + capabilities into the memQL engine.

Lifted from `github.com/znasllc-io/memql` on 2026-05-14 as part
of the monorepo carve-up.

## Module structure

- `dsl/__PRODUCT__/` -- __PRODUCT__ DSL tree
  - `concepts.memql` -- v1:__PRODUCT__:* concept schemas
  - `mutations.memql` -- writes (createCanvasState, archiveSpace, ...)
  - `queries.memql` -- reads (canvasStatesForSpace, ...)
  - `shapes.memql`, `specs.memql`, `automations.memql`,
    `builtins.memql`, `tools.memql`, `prompts.memql`, `logic.memql`
  - `prompts/` -- template files (agentReply.tmpl, refineAnalysis.tmpl,
    inferEntitySchema.tmpl, planEstimate.tmpl, augmentDomainAnalyze.tmpl,
    augmentDomainContent.tmpl, agentSystemPromptDistill.tmpl)
- `integrations/__PRODUCT__/` -- Go plug-in code
  - `plugin.go` -- self-registers via `memql.RegisterPlugin()` from `init()`
  - `conversation.go` -- backs the `__PRODUCT__Conversation` tool
  - `routing.go` -- registers `graph.node.*.v1:__PRODUCT__:*` event routing
- `app/plugins___PRODUCT__.go` -- blank-import anchor (drag the
  integration into the binary's init graph)

## Build

```bash
go build ./...
go vet ./...
go test ./...
```

### Tests + CI

`.github/workflows/ci.yml` runs two lanes against the sibling memQL engine
(`../memql`, resolved via the `replace` in `go.mod`):

- **go-checks** — `build` + `vet` + `go test ./...`. Includes
  `dsl/__PRODUCT__/__PRODUCT___tree_load_test.go`, the **DSL load gate**: it boots
  a real engine with the __PRODUCT__ tree mounted and fails if ANY __PRODUCT__
  construct stops loading against the engine (the guard against silent grammar
  drift). DB-gated tests self-skip here.
- **db-tests** — seeds a TimescaleDB + extensions and runs the DB-seeded
  behavioural suite (`dsl/__PRODUCT__`), e.g. the saved/archived space-list
  gating guard. To run these locally, point `MEMQL_DATABASE_DSN` at a
  TimescaleDB (with the `timescaledb`, `uuid-ossp`, `pgcrypto`, `vector`
  extensions); without it they skip.

This module is the deployable **__PRODUCT__ BFF carrier**: the memQL
engine (pinned in `go.mod`) compiled together with the __PRODUCT__ DSL +
integrations into one node binary. The carrier release image is cut by:

```bash
make release ARGS="--dry-run"                 # plan only
make release                                  # local memql-bff-__PRODUCT__:0.1.0 image
make release ARGS="--acr=acrmemql --push"     # build + push to the shared ACR
```

`make release` wraps `scripts/release/release.sh`, which builds an
immutable `memql-bff-__PRODUCT__:X.Y.Z` image from the `VERSION` file +
short git SHA. The image is write-once (re-cutting a tag needs
`--allow-overwrite`) and stamps the source commit as an OCI
`org.opencontainers.image.revision` label. Because `go.mod` carries a
`replace ... => ../memql`, the Dockerfile build context spans both
`memql/` and `memql-bff-__PRODUCT__/`, so the script builds from the
workspace parent. See `scripts/release/release.sh --help` for all flags.

## Releasing & versioning

This module is the deployable **__PRODUCT__ BFF carrier**, released as an
immutable `memql-bff-__PRODUCT__:X.Y.Z` image (see "Build" above) and also
importable as a semver-tagged Go module.

It sits in the middle of a three-link pin chain:

```
__PRODUCT__  --pins-->  memql-bff-__PRODUCT__:X.Y.Z  --pins-->  memql @ v__ENGINE_VERSION__
 (carrier-version          (this carrier image,            (engine, go.mod
  deploy file,              make release)                    require + tag)
  __PRODUCT__#140)
```

- **__PRODUCT__ pins the carrier version** (an image tag) via its
  carrier-version deploy file.
- **the carrier pins the memQL engine** via `go.mod`
  (`require github.com/znasllc-io/memql v__ENGINE_VERSION__`) — see "memQL core
  dependency" below.

The carrier baseline is **0.1.0** (see [`VERSION`](VERSION) and
[`VERSIONING.md`](VERSIONING.md)), superseding the interim `v0.2.0`.
**1.0.0** is reserved for the public beta. The git tag is the source of
truth; the cross-component compatibility matrix lives in memQL's hub
[`COMPATIBILITY.md`](https://github.com/znasllc-io/memql/blob/main/COMPATIBILITY.md).

### Versioning policy

- Tags follow `vMAJOR.MINOR.PATCH` (e.g. `v0.1.0`).
- We stay in **v0.x** for now. Go only requires the `/vN` module-path
  suffix at v2 and above, so staying in v0.x keeps the import path clean
  (`github.com/__PRODUCT_ORG__/__PRODUCT__-carrier`, no `/v2`).
- The module path in `go.mod` already matches the repo URL, so the module
  is import-ready as a tagged dependency with **no `replace` required on
  the consumer side** (see "memQL core dependency" below for why the local
  `replace` here does not leak downstream).

### Cutting a release

Tags are cut from `main` after the relevant PR merges:

```bash
git checkout main && git pull --ff-only
# pick the next semver tag (bump patch/minor/major as appropriate)
git tag v0.1.0
git push origin v0.1.0
```

Use an annotated tag if you want a release message:
`git tag -a v0.1.0 -m "release v0.1.0"`.

### How memQL consumes a pinned version

In the memQL core repo (`github.com/znasllc-io/memql`):

```bash
go get github.com/__PRODUCT_ORG__/__PRODUCT__-carrier@v0.1.0
go mod tidy
```

This writes the exact version into memQL's `go.mod` and records the hash
in `go.sum`. Release builds then resolve the tagged source from the Go
module proxy / git, independent of any local checkout.

**Local development is unaffected:** the sibling `go.work` in
`/Users/znas/projects` (`use ./memql ./memql-bff-__PRODUCT__ ...`) still
overrides the pinned versions with the working trees, so day-to-day work
continues against live source.

## Wiring into a memQL BFF binary

Until a cleaner extension-point lands, the memQL core's `app/`
package (the BFF binary's bootstrap) needs to blank-import this
module's integration package:

```go
import _ "github.com/__PRODUCT_ORG__/__PRODUCT__-carrier/integrations/__PRODUCT__"
```

This triggers the package's `init()` functions:
- `memql.RegisterPlugin("__PRODUCT__", factory)` -- registers the
  __PRODUCT__ integration capability.
- `node.RegisterRoutingRule(...)` -- registers event routing for
  `graph.node.created/updated/deleted.*.v1:__PRODUCT__:*`.

DSL files in `dsl/__PRODUCT__/` need to be loaded by the engine. The
engine's `MEMQL_DSL_PATH` overlay mechanism is the intended path:
point it at this repo's `dsl/` directory at deploy time, or vendor
the DSL tree into the core binary's embed graph.

## Known cross-contamination

A handful of files in memql core still hardcode `v1:__PRODUCT__:*`
concept ids in dispatch logic (cognition routing, planner, delegate
takeover, voice-agent handler, attachment handler). These should be
cleaned up via extension points before this repo becomes authoritative
for everything __PRODUCT__.

## memQL core dependency

This module depends on `github.com/znasllc-io/memql` for:
- `component/memql` -- plugin context + engine types
- `component/database/memory-nodes` -- row helpers
- `component/node` -- routing rule registration

The engine is pinned in `go.mod` with two coupled lines:

```
require github.com/znasllc-io/memql v__ENGINE_VERSION__          // release pin (authoritative)
replace github.com/znasllc-io/memql => ../memql     // source location for dev/CI/Docker
```

- The **require** is the authoritative engine pin — `v__ENGINE_VERSION__`, the memQL
  release this carrier ships against. `GOWORK=off go list -m
  github.com/znasllc-io/memql` resolves it to `v__ENGINE_VERSION__`; the
  `scripts/release` test `TestMemqlPinResolves` guards the pin.
- The **replace** redirects the *source location* (not the version) to the
  sibling `../memql/` tree, so the module builds standalone against live
  core source in local dev, in the hermetic carrier Dockerfile build (which
  COPYs both trees), and in the `govulncheck` CI job (whose default
  `GITHUB_TOKEN` cannot fetch the private `znasllc-io/memql` over the
  proxy). When the engine *is* fetched from the remote, the global
  `url."git@github.com:".insteadOf "https://github.com/"` git config pulls
  the private tag over SSH.

**This `replace` does not leak into downstream consumers.** Go applies
`replace` directives only from the *main* module being built; the `replace`
lines in a *dependency's* `go.mod` are ignored. So a consumer that depends
on a tagged `memql-bff-__PRODUCT__` resolves `github.com/znasllc-io/memql`
from its own module graph, not from this `../memql`. The carrier is
therefore tag-consumable as-is.
