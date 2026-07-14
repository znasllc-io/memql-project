# Design: the thin `bff/` Go escape-hatch payload

**Status:** design only -- no implementation until a product actually needs
bespoke Go.
**Tracks:** [memql-project#11](https://github.com/znasllc-io/memql-project/issues/11)
(design backlog under the Step-5 consolidation epic).
**Decision basis:** [memql#2472](https://github.com/znasllc-io/memql/issues/2472)
decision 2 -- product Go is absorbed into the engine as generic features; only
truly bespoke, one-of-a-kind Go survives, as a thin bff plugin.

This document specifies the payload a product adds **only when it first needs
client-specific Go**, and how that payload composes with the stamped product
repo (init.sh, the deploy overlays, CI) without disturbing anything a no-Go
product relies on. It is a design, not a landed feature: the shapes below are
what the future implementer builds, turned into an implementation checklist at
the end.

Engine-contract API names, signatures, and file locations in this document were
verified against the engine clone at HEAD `3a89674f` (the ref this template
targets, `ENGINE_REF=main`). The "Verified engine contract surface" table is the
authority; re-verify against the stamped `ENGINE_REF` at implementation time.

---

## 1. When to reach for it (the decision rubric)

Bespoke Go is the **last** resort, not a convenience. Engine packs are compiled
in via build tags -- there is **no runtime loading of the Go half** (Plugin SDK,
"Scope"). A product that ships Go therefore stops running on the neutral,
product-agnostic engine image and starts shipping a **custom node image** it
must build, pin, and keep current with the engine. That is a real, permanent
operational cost. Exhaust these first, in order:

1. **Pure DSL.** A pack can model concepts, read/write them (queries/mutations),
   react to graph events (automations calling logic/mutations), and expose agent
   tools -- all with **zero product Go**, delivered at runtime via the DSL
   bundle. This is the whole point of the DSL-first product. Most "we need code"
   turns out to be an automation + logic chain.
2. **An engine-generic capability.** If the Go you want is something a *second
   product would also want* (an object-store integration, an email dispatcher, a
   new builtin family), it belongs in the **engine** as a generic feature, not in
   your repo. This is the standing change-routing rule: "would a second product
   want this? -> the engine." Open an engine issue for the missing seam.
3. **Only then, a `bff/` plugin.** Reach here **only** for Go that is genuinely
   one-of-a-kind to this one product and cannot be expressed in DSL: a bespoke
   external-protocol adapter, a client-specific algorithm with no general form, a
   proprietary integration that would never be upstreamed.

The `@executor("integration.<name>.*")` builtin is the **only** DSL construct
that needs Go behind it. If your DSL never names an `@executor` you do not need
this payload. If it does, and the executor cannot be a generic engine
capability, you have found the escape hatch's use case.

**Litmus test.** Before adding `bff/`, write the engine issue you *would* file to
get the capability upstreamed. If that issue is coherent ("memQL should ship an
X integration"), do that instead. If the issue reads as "memQL should ship
$CLIENT's proprietary X" -- i.e. no second product wants it -- the `bff/`
plugin is correct.

---

## 2. Payload layout

The payload is an **optional Go module** added under `bff/` by
`init.sh --go-module`. It is deliberately thin: every line of general service
behavior stays in the engine; the module adds only this product's
`IntegrationProvider` and wraps the engine's own `app.Run` lifecycle so the
product bff boots exactly like the neutral engine bff, plus the product plugin.

```
<product>/                         THIS repo (stamped)
├── bff/                           the optional Go module (only with --go-module)
│   ├── go.mod                     module github.com/<org>/<product>-bff
│   │                              replace github.com/znasllc-io/memql => ../memql
│   ├── main.go                    mirrors the engine main.go; blank-imports the pack
│   ├── Dockerfile                 thin: builds the one bff binary vs the sibling engine
│   ├── integrations/<product>/
│   │   └── plugin.go              package pack: IntegrationProvider + init() registrations
│   └── import_smoke_test.go       compiles the blank-import surface; init() must not panic
├── dsl/<product>/                 UNCHANGED -- the .memql pack stays runtime-bundled
├── deploy/                        overlay bff image re-pinned to <product>-bff (section 4)
└── go.work                        generated: use ./bff + ../memql (+ ../memql-cockpit); gitignored
```

### 2.1 `bff/main.go` -- wrap the engine, add the pack

The product bff binary is the engine's default (`bff`, no build tag) entrypoint
with **one** addition: a blank import of the product integrations package, whose
`init()` registers the plugin. Everything else -- genesis autoload, `.env`
override, legacy-env aliasing, `app.Run` with the graceful-shutdown and health
wiring -- is copied from the engine's own `main.go` so the product bff has
byte-for-byte the same lifecycle.

```go
package main

import (
	// ... the same imports the engine main.go uses (app, genesis, server,
	// service, common, logger) ...

	// Blank import: the product pack registers from init(). This is the ONLY
	// line that differs from the engine's own main.go.
	_ "github.com/<org>/<product>-bff/integrations/<product>"
)

func main() {
	// byte-for-byte the current engine main.go body:
	//   genesis.AutoloadFromEnv() -> genesis.ApplyLocalOverride(".")
	//   -> genesis.ApplyLegacyEnvAliases() -> app.Run(app.RunConfig{ ... })
}
```

The product DSL still loads at runtime: `app.Run` -> `app/database.go` calls
`dsl.MountRuntimeDomainsFromEnv`, which mounts the bundle at `MEMQL_DSL_PATH`.
The bff image keeps mounting the same DSL bundle it does today; the Go module
adds only the executor implementation the bundle's `@executor` builtins name.

> **Do NOT lift the archived `main.go` verbatim.** The engine's `main.go` has
> drifted since `archive/carrier-payload` was cut: it gained subcommand dispatch
> (`dispatchSubcommand`) and graceful-shutdown `RunConfig` fields (`BeginDrain`,
> `DrainDelay`, `GracePeriod`, `ActiveWork`) that the archived carrier `main.go`
> lacks. Re-mirror the **current** engine `main.go`, not the archive. (This is
> the single biggest engine-contract drift the salvage map calls out.)

### 2.2 `bff/integrations/<product>/plugin.go` -- the pack

One file, package named `pack` (a valid Go identifier for any product slug),
holding the `IntegrationProvider` and a single build-tag-**un**gated `init()`
that runs for every node type this image is built as (only `bff`, in the common
case). The three registration primitives:

```go
package pack

const integrationName = "<product>" // the @executor middle segment

// Pin the contract version this pack compiled against; the loader rejects a
// stale pack at startup (exact-major equality) instead of mis-binding.
const ContractVersion = memql.PluginContractVersion

type Provider struct{}

func (p *Provider) IntegrationName() string { return integrationName }
func (p *Provider) Capabilities() []memql.IntegrationCapability { /* ... */ }

// PluginFactory: build the Provider from the live PluginContext. Return
// (nil, nil) to opt out cleanly when deps are missing.
func NewProvider(pctx memql.PluginContext) (memql.IntegrationProvider, error) {
	return &Provider{}, nil
}

func init() {
	memql.RegisterPluginForContract(integrationName, ContractVersion, NewProvider)

	// Only if a graph event must cross a node boundary in cluster mode.
	node.RegisterRoutingRule(node.RoutingRule{ /* Pattern, TargetType */ })
}
```

- **`RegisterPluginForContract`** (not `RegisterPlugin`): third-party packs
  SHOULD declare the contract version explicitly so a version mismatch fails
  loudly. `RegisterPlugin` stamps the current version implicitly -- fine for
  in-engine packs, not for a downstream product.
- **`RegisterTree` is deliberately absent in the recommended shape.** The
  product's `.memql` stays in the runtime bundle (`dsl/<product>/` +
  `Dockerfile.bundle` + the `dsl-bundle` component, all unchanged), so the
  engine mounts it via `MountRuntimeDomainsFromEnv` at boot -- the Go module
  registers only the *executor*, not the DSL. See "Compiled-in DSL variant"
  below for the alternative and its hard constraint.
- **`RegisterRoutingRule`** only when the pack emits an event on one node type
  that must be consumed on another; the minimal pack omits it.
- **Capability handler signature** is the engine's builtin-executor handler:
  `func(ctx context.Context, args map[string]any, target int) ([]memorynodes.MemoryNode, error)`
  (the unexported `builtinExecutorHandler` alias; re-verify at implementation).
  A capability named `composeGreeting` on integration `<product>` is callable
  from DSL as `@executor("integration.<product>.composeGreeting")`.

**Registration order is automatic on the app path.** A pack's builtin resolves
its Go capability by FQN at *dispatch* time. `app.materializePlugins` registers
every pack provider *after* `engine.Init`, so a `bff/` binary wrapping `app.Run`
never hits the "register-before-Init" gotcha the pack guide warns hand-wired
test harnesses about.

### 2.3 Compiled-in DSL variant (alternative, not the default)

If a product's Go integration ships `.memql` so tightly coupled it must version
in lockstep with the Go (rare), the pack can embed that DSL and mount it via
`dsl.RegisterTree(domain, embeddedFS)` from `init()` (the archived carrier
`dsl/<product>/embed.go` is the salvage shape). **Hard constraint:** a given DSL
domain is **either** runtime-bundled **or** compiled-in, never both --
`dsl.RegisterTree` -> `dsl.ValidatePackDomain` **panics** at `init()` on a domain
collision. So if you embed domain `<product>`, you must remove it from the
runtime bundle (or embed a *separate* Go-adjacent domain, e.g.
`<product>internal`). The default recommendation is runtime-bundle everything and
keep the Go module DSL-free: it preserves the DSL-first delivery mechanism and
keeps the bff image swappable without a DSL rebuild.

### 2.4 `bff/go.mod` and the `replace`

```
module github.com/<org>/<product>-bff
go 1.26.x
require github.com/znasllc-io/memql v0.0.0-00010101000000-000000000000
replace github.com/znasllc-io/memql => ../memql
```

The **`replace => ../memql` is the load-bearing mechanism**: it points the build
at the sibling engine checkout, so Go reads `../memql` directly and never fetches
from a proxy (the private engine needs no module auth). The `require` version is
cosmetic under the replace -- keep the canonical local-replace pseudo-version,
not the human-facing engine pin (a git ref like `main` is not a valid go.mod
version). The engine ref the product ships against is recorded in `product.env`
(`ENGINE_REF`) and the deploy overlays, where a git ref is the right form. Run
`go mod tidy` after the engine sibling is present to populate `go.sum` for the
engine's transitive deps.

### 2.5 `go.work` (generated, gitignored)

```
go 1.26.x
use (
	./bff
	../memql
	../memql-cockpit   // if present
)
```

`go.work` at the **product repo root** is a local-dev convenience: it lets edits
in `../memql` flow through to `go build ./bff/...` without a `go mod tidy`. It is
**generated** by `init.sh --go-module` and **gitignored** -- never committed --
because it references `../memql` (a sibling that a fresh clone without the
workspace does not have; a committed `go.work` would break every `go` command on
such a checkout). Both the Docker build and CI set `GOWORK=off` and rely on the
`replace` instead, so `go.work` is strictly optional sugar. `.gitignore` already
carries the Go block (see section 3.3).

### 2.6 `bff/Dockerfile` -- thin, one image

The archived carrier Dockerfile built a **five-node matrix** (bff / cognition /
agent / planner / workbench) because pre-#2472 the product DSL was compiled into
every node. That is gone. Post-consolidation the product DSL rides at runtime on
the neutral leaf nodes, so the bespoke-Go payload builds **exactly one image**:
the product's own `bff` head (default build, no tag). The Dockerfile:

- sets the build **context to the workspace root** (parent of `memql/` and the
  product repo) so `COPY` can pull in **both** sibling trees -- the
  `replace => ../memql` resolves the same way `go build` does locally;
- copies `go.mod`/`go.sum` first for layer caching, then full source;
- runs the engine's `templ generate` + `build-css.sh` (the bff statically links
  the engine identity package's generated files) inside the engine tree;
- `CGO_ENABLED=0 go build` (no `-tags`, bff is the default) the single binary
  against the sibling engine, plus the engine's `cmd/healthcheck`;
- distroless runtime carrying the binary + the engine `VERSION`.

Only the **base-prefix + single compile** stages of the archived Dockerfile
survive; the `CARRIER_BASE` external-base indirection and the five-tag matrix do
not (there is one image, so nothing to dedup across tags).

---

## 3. `init.sh` changes

The keystone that keeps template-sync clean:

> **Byte-identical operational files (Makefile, `ci.yml`, `.gitignore`) carry
> the escape-hatch scaffolding shipped INERT and gated on `bff/` existing.
> `init.sh --go-module` only generates product-specific content (the `bff/`
> module, `go.work`, and the deploy image re-pin). Nothing `init.sh` does
> diverges a byte-identical file**, so `git merge template/main` stays clean for
> Go and no-Go products alike.

### 3.1 The `--go-module` flag

A new declared flag (`cap_spec_param "go-module"`), added to `CAP_KNOWN_FLAGS`.
When set, `init.sh` additionally:

1. **Generates the `bff/` tree** with the product identity already interpolated
   at write time -- `main.go`, `integrations/<product>/plugin.go`,
   `import_smoke_test.go`, `go.mod` (module path `github.com/<org>/<product>-bff`,
   the `replace`), and `Dockerfile`. Interpolating at generation (like
   `write_product_env` / `replace_readme` already do) means **no `__TOKEN__`
   literals ever land in `bff/`**, so `bff/` needs no entry in `CAP_STAMP_PATHS`
   and there is nothing for a later re-run to re-stamp.
2. **Generates `go.work`** at the repo root (`use ./bff` + `../memql` + cockpit
   if cloned).
3. **Re-pins the deploy bff image** in the overlays from the neutral engine
   `memql-bff` to the product image `<product>-bff` (section 4).

`bff/` and `go.work` are **product-specific by nature** (they carry the module
path and the product's Go). They are absent from a pristine template checkout, so
`git merge template/main` never touches them -- no conflict, no re-prune dance.

### 3.2 Idempotency + identity-guard interaction

- **Idempotent re-runs.** A `--go-module` re-run when `bff/` already exists is a
  no-op with honest `changed=false` (compare-before-write, as
  `write_product_env` does). Generation must be `cmp`-guarded per file.
- **Non-destructive.** A re-run *without* `--go-module` on a repo that already
  has `bff/` must **not** delete it -- `init.sh` never owns removal of
  product-authored code. (Add a one-line `cap_info` noting `bff/` is present but
  `--go-module` was not passed, so the state is legible.)
- **Identity guard rides for free.** The existing B1 guard
  (`reconcile_with_existing_env`) refuses (exit 3, no mutation) a re-stamp whose
  `product`/`org` disagrees with the stamped `product.env` *before* any file is
  written. Because the `bff/` module path (`github.com/<org>/<product>-bff`) and
  `plugin.go`'s import paths + `integrationName` are interpolated from that same
  identity, a mismatched re-stamp is refused before `bff/` is ever touched -- the
  module can never half-apply to a new identity. No new guard logic is needed;
  the `--go-module` generation must simply run **after**
  `reconcile_with_existing_env` / `detect_orphaned_stamp`, inside the same
  post-guard mutation block as the existing steps.
- **`--dry-run` parity.** The dry-run plan must add a "would generate: bff/ Go
  module + go.work; would re-pin the deploy bff image" line and mutate nothing,
  so the capability-conformance CI lane (which asserts dry-run leaves the tree
  untouched) stays green.

### 3.3 `.gitignore`

**No init-time edit.** The template `.gitignore` already ships the Go ignore
block inert -- with the exact comment *"Go (only if a product later adds a bff
plugin module -- memql-project#11)"* and `go.work.sum`. The **only** addition
this design needs is the `go.work` file itself (currently only `go.work.sum` is
listed). That one line ships in the **template** `.gitignore` (harmless inert on
a no-Go product -- no `go.work` exists to ignore), preserving the byte-identical
invariant. `init.sh` does not touch `.gitignore`.

---

## 4. Deploy changes

The product bff Deployment (`deploy/k8s/base/bff.yaml`, `bff-<product>`) already
runs `image: memql-bff` retargeted per overlay. For a bespoke-Go product the
**only** deploy change is the overlay `images:` re-pin -- the Deployment spec,
the `dsl-bundle` component, and the runtime DSL mount are all unchanged.

- **Name convention:** `<product>-bff` in the product registry, parallel to the
  existing `<product>-dsl-bundle` and `<product>-client`. The `images:`
  transformer rewrites the base `memql-bff` name:
  - **local** overlay: `newName: <product>-bff`, `newTag: local` -- a
    k3d-imported mutable tag (mirrors `<product>-dsl-bundle:local`).
  - **staging/prod** overlays: `newName: <registry>/<product>-bff`
    (the registry token init substitutes), `digest: sha256:0000...0000` -- the
    all-zeros fail-closed placeholder the
    build server replaces at activation, exactly as `<product>-dsl-bundle` and
    `<product>-client` are pinned today.
- **The neutral `memql-bff` tag-pin is only for no-Go products.** A no-Go
  product keeps the engine `memql-bff` image pinned by **tag** to `ENGINE_REF`
  (an engine-registry image, `acrmemql.azurecr.io/memql-bff`). A Go product
  swaps that entry for the product-registry `<product>-bff` **digest**.
- **Digest gate composition (a required CI change, section 5.3).** The existing
  deploy-lane digest gate hardcodes the product-image set as `(-dsl-bundle |
  -client)` and asserts `>= 2` such images, all `@sha256`-pinned. A product bff
  is a **third** product image. Adding `-bff` to that literal pattern
  unconditionally would break **no-Go** products, whose bff is the tag-pinned
  engine `memql-bff`. Resolve by **generalizing the gate rule**: *every
  product-registry image (`<registry>/...`) must be digest-pinned;
  engine-registry images (`acrmemql.azurecr.io/...`, tag-pinned to `ENGINE_REF`)
  are exempt.* That reframing covers the optional bff without a per-product CI
  diff and keeps the `>= 2` floor (bundle + client) intact, with the bff an
  optional third. This gate change ships in the **template** `ci.yml` (inert for
  no-Go products -- they render zero `<product>-bff` lines).

The overlay activation checklists gain one line: "if this is a bespoke-Go
product, replace the `<product>-bff` all-zeros digest with the built image
digest," alongside the existing bundle/client digest steps.

---

## 5. CI additions

Same keystone as init: the Go lane ships **in the template `ci.yml`, inert**, so
`ci.yml` stays byte-identical across all products. It is **path-filtered on
`bff/**`** and skips wholesale on a no-Go product (which has no `bff/`, so
`bff/**` is never in a diff). `init.sh --go-module` does **not** edit `ci.yml`.

Rejected alternative: injecting the lane via `init.sh --go-module`. That diverges
the Go product's `ci.yml` from the template and reintroduces a
`git merge template/main` conflict on CI -- exactly the breakage the
byte-identical invariant exists to prevent.

### 5.1 The `bff` lane

Add to the `changes` job a `bff` output (`emit bff '^bff/'`), and a new job:

```yaml
bff:
  name: bff
  needs: changes
  if: needs.changes.outputs.bff == 'true'
  runs-on: ubuntu-latest
  env:
    GOWORK: off            # the replace is authoritative; no go.work in CI
  steps:
    - uses: actions/checkout@... (this product repo)
    - uses: actions/checkout@... # engine as a sibling ../memql for the replace
      with: { repository: znasllc-io/memql, path: ../memql, ref: <ENGINE_REF> }
    - uses: actions/setup-go@... { go-version: '1.26.4' }
    - run: go build ./...   # working-directory: bff
    - run: go vet ./...     # working-directory: bff
    - run: go test ./...    # working-directory: bff  (DB-gated suites self-skip)
```

- **Sibling engine at the stamped `ENGINE_REF`.** Read `ENGINE_REF` from
  `product.env` (same pattern as the existing `dsl` lane), clone the engine
  sibling at that ref, and **fail hard on a clone miss** -- no silent fallback to
  `main` (the dsl lane's C2 rule). The pack is authored against that ref's
  contract, so building against it is what keeps the lane honest.
- **`GOWORK=off`.** CI relies purely on `bff/go.mod`'s `replace => ../memql`, so
  the checkout must place the engine where the replace resolves (`../memql`
  relative to the module). The archived carrier used a two-checkout layout
  (`memql-bff-<product>` + `memql` siblings); mirror whichever layout makes the
  relative `replace` resolve.
- **`ci-required` aggregate.** Add `bff` to the `ci-required` `needs:` list. It
  already accepts `skipped` as success, so a no-Go product (bff lane skipped)
  stays green with no special-casing.

### 5.2 Existing lanes are untouched

`shellcheck`, `capability-conformance`, `client`, `deploy`, `dsl` are unchanged.
The `changes` filter already runs everything when `.github/`, `scripts/`, or
`product.env` change; the `bff` lane simply joins the path-filtered set. A no-Go
product sees the `bff` lane defined-but-always-skipped, exactly like a product
that touches no `client/` sees the `client` lane skip.

### 5.3 Digest gate

The deploy-lane digest-gate generalization (product-registry -> digest-pinned;
engine-registry -> exempt) from section 4 lands in the same template `ci.yml`.
Inert for no-Go products.

### 5.4 Optional: a DB-tests lane

If a product's bff plugin has DB-backed behavior, the archived carrier `ci.yml`'s
`db-tests` job is the salvage shape: a `timescaledb:latest-pg16` service, the
extension-seeding step (`timescaledb`, `uuid-ossp`, `pgcrypto`, `vector`), and
`go test ./integrations/<product>/...` under
`MEMQL_DATABASE_DSN=postgres://...`. This is **not** in the default lane -- add it
per product only when the plugin needs Postgres. If it is added to the template
`ci.yml`, it must also be `bff/**`-path-filtered and skip without `bff/`.

---

## 6. Salvage map -- `archive/carrier-payload`

Exact paths worth lifting when implementing, and what stays dead. All paths are
under `templates/carrier/` on branch `archive/carrier-payload` unless noted;
`<product>` stands for the product-slug token the archive carries in those path
names.

### 6.1 Lift (adapt to the current contract)

| Archive path | Lift as | Notes / drift |
|---|---|---|
| `main.go` | `bff/main.go` shape | **Re-mirror the CURRENT engine `main.go`, not this file.** The archive predates subcommand dispatch + graceful-shutdown `RunConfig` fields. Keep only the blank-import-the-pack idea. |
| `integrations/<product>/plugin.go` | `bff/integrations/<product>/plugin.go` | Provider + `NewProvider` + `init()` with `RegisterPluginForContract` (+ `RegisterRoutingRule`). Handler signature still current. Drop the DSL blank-import unless using the compiled-in variant (2.3). |
| `dsl/<product>/embed.go` | only for the **compiled-in DSL variant** (2.3) | `//go:embed all:*.memql` + `dsl.RegisterTree`. Omit in the default runtime-bundled shape. |
| `dsl/<product>/load_test.go` | a `bff/` load test | `dslimports.Load(os.DirFS(...))` still current -- but the default shape's DSL lives in `dsl/<product>/`, already covered by the `dsl` memqllint lane. Use for compiled-in DSL only. |
| `app/import_smoke_test.go` | `bff/import_smoke_test.go` | Blank-import-compiles + `init()`-doesn't-panic gate. Simplest useful Go test; keep. |
| `Dockerfile` (base-prefix + compile stages) | `bff/Dockerfile` | Keep the two-tree context + templ/css generate + single `go build`. **Drop** the five-tag matrix and `CARRIER_BASE` external-base indirection (one image now). |
| `go.mod` (`replace => ../memql`) | `bff/go.mod` | The replace rationale + cosmetic-require note still hold verbatim. |
| `go.work` | root `go.work` | Rework `use` list to `./bff` + `../memql` (single-repo layout, not the old multi-repo constellation). |
| `.github/workflows/ci.yml` (`go-checks`, `db-tests`) | the template `bff` lane (5.1) + optional db-tests (5.4) | Sibling-engine checkout + `GOWORK=off` pattern is the model. |
| `scripts/sdk-gen/main.go` | optional `bff/scripts/sdk-gen` | `sdk/gen` (`gen.Options` / `gen.Generate`) still exists in the engine. Only if the product publishes a typed TS SDK; the current template client is self-contained (no SDK), so this is out of scope until a product needs a published SDK. |

### 6.2 Stays dead (do not resurrect)

- **The release lockfile estate:** `scripts/release/*`, `releases/*.yaml`,
  `release-lockfile*.yml`, `publish-releases.yml`, `VERSIONING.md`. Superseded by
  the two-Application composition + overlay digest pins.
- **The Azure/AKS deploy estate:** `scripts/deploy/aks-*.sh`,
  `*-provision.sh`, `bff-bluegreen-cutover.sh`, `post-deploy-gate.sh`,
  `staging-*.sh`, `deploy-drift.yml`, `build-carrier-images.yml`,
  `cluster-e2e.yml`, `govulncheck.yml`, `carrier-heavy.yml`. Deploy is ArgoCD +
  overlays now.
- **The five-node image matrix:** `CARRIER_BASE`, the `-tags {cognition,agent,
  planner,workbench}` builds. Product DSL rides the neutral leaf nodes at
  runtime; only the bff is a product image.
- **The SDK publish/driftcheck workflows** (`<product>-sdk-*.yml`) and the
  committed `sdk/ts/**` -- unless a product actually publishes a typed SDK.
- **The whole `templates/carrier/` multi-repo framing** (carrier-as-separate-repo,
  `app/plugins_<product>.go` anchor file). The consolidated model puts the pack
  in `bff/` inside the one product repo; a single `main.go` blank-import replaces
  the `app/` anchor file.

---

## 7. Open questions

1. **Bespoke Go on a leaf node.** The default escape hatch produces one product
   image: the **bff**. If a product's Go executor must run on a **leaf** node
   (an automation dispatching the builtin on `agent`/`cognition`), that leaf is a
   neutral engine image and would *also* have to become a product image -- a
   multi-image escape hatch this design does not cover. Today only the
   `bff-<product>` Deployment carries the product DSL (`memql/product-dsl=true`),
   so builtins dispatch on the bff. Decide, when a product forces it, whether
   leaf-node bespoke Go is in scope or an engine-generic-capability push-back.
2. **`go.work` location vs. the single-repo model.** This design puts `go.work`
   at the product repo root (`use ./bff` + `../memql`) and gitignores it. An
   alternative is a parent-dir workspace `go.work` (never in any repo). Repo-root
   + gitignored matches the issue's phrasing and keeps the file regenerable;
   confirm at implementation.
3. **Go toolchain version pinning.** `bff/go.mod`'s `go 1.26.x` and the CI
   `setup-go` version must track the engine's. Where is the single source --
   read the engine `go.mod`, or pin in `product.env`? (No cross-file drift gate
   exists yet.)
4. **`go mod tidy` / `go.sum` hygiene.** The `replace` means `go.sum` carries no
   engine hash but must carry the engine's transitive-dep hashes. Who runs
   `go mod tidy`, and does CI gate on a dirty `go.sum`?
5. **SDK generation demand.** Ship the `sdk-gen` salvage now (behind an
   `init.sh --go-module --with-sdk`?) or defer until a product publishes a typed
   SDK? Current lean: defer -- the template client is self-contained.

---

## 8. Non-goals

- **No implementation.** This is a design; the `bff/` payload is not built until
  a real product needs bespoke Go and forces the concrete shape.
- **No engine changes.** The engine stays product-agnostic. A missing seam is an
  **engine** issue, not a reason to widen this payload.
- **No compat shims (pre-1.0).** `PluginContractVersion` is exact-major; a stale
  pack fails loudly at startup. This design adds **no** version-bridging or
  backward-compat layer -- the product re-pins and rebuilds against the engine
  ref it ships with.
- **No multi-image / leaf-node Go** in the default hatch (open question 1).
- **No release-lockfile or Azure deploy resurrection** (section 6.2).
- **No published SDK** by default (the client stays self-contained).

---

## 9. Verified engine contract surface

Verified against the engine clone at HEAD `3a89674f`. Re-verify against the
stamped `ENGINE_REF` when implementing.

| Symbol | Signature / value | Location |
|---|---|---|
| `memql.PluginContractVersion` | `const = 1` (int) | `component/memql/plugins.go:34` |
| `memql.RegisterPluginForContract` | `(name string, requiresContractVersion int, factory PluginFactory)` | `component/memql/plugins.go:194` |
| `memql.RegisterPlugin` | `(name string, factory PluginFactory)` (implicit version) | `component/memql/plugins.go:183` |
| contract check | exact-major: `if requiresContractVersion != PluginContractVersion` | `component/memql/plugins.go:163` |
| `memql.CheckPluginContractCompat` | `(version int) error` (pure form) | `component/memql/plugins.go` |
| `memql.PluginFactory` | `func(pctx PluginContext) (IntegrationProvider, error)` | `component/memql/plugins.go:123` |
| `memql.PluginContext` | struct (Logger, Engine, BunDB, resolvers, registries) | `component/memql/plugins.go:45` |
| `memql.IntegrationProvider` | `interface { IntegrationName() string; Capabilities() []IntegrationCapability }` | `component/memql/integration_provider.go:58` |
| `memql.IntegrationCapability` | `struct { Name, Description string; Handler builtinExecutorHandler; ArgsSchema map[string]string; PreserveOrder bool }` | `component/memql/integration_provider.go:6` |
| capability handler | `func(ctx context.Context, args map[string]any, target int) ([]memorynodes.MemoryNode, error)` | `component/memql/executor.go:18` |
| `dsl.RegisterTree` | `(domain string, tree fs.FS)` | `dsl/embed.go:86` |
| `dsl.ValidatePackDomain` | `(domain string, coreDomains, existing []string) error` (panics via RegisterTree on collision) | `dsl/pack_validation.go:59` |
| `dsl.MountRuntimeDomainsFromEnv` | `(logger *slog.Logger) []string` (the runtime bundle mount) | `dsl/runtime_mount.go:37`, called `app/database.go:32` |
| `node.RoutingRule` / `node.RegisterRoutingRule` | `struct` / `(rule RoutingRule)` | `component/node/routing.go:10,33` |
| `app.Run` / `app.RunConfig` / `app.Overrides` | `func(cfg RunConfig)` / struct / struct | `app/run.go:169,66`, `app/app.go:44` |
| `dslimports.Load` | `(root fs.FS) (*Tree, error)` | `component/memql/dslimports/dslimports.go:71` |
| `sdk/gen` | `gen.Options` / `gen.Generate(opts Options) (*Result, error)` | `sdk/gen/gen.go:116,169` |
| bff build tag | default (no tag); tags mutually exclusive; product DSL runtime-delivered | `docs/public/build/build-tags.md` |

---

## 10. Implementation checklist (for the future implementer)

When a product first forces bespoke Go, turn this design into issues:

1. **`init.sh --go-module` flag** -- declare the param, add to `CAP_KNOWN_FLAGS`,
   generate the `bff/` tree (identity interpolated at write time, `cmp`-guarded),
   generate root `go.work`, re-pin the deploy bff image. Runs in the post-guard
   mutation block; dry-run plan + parity; non-destructive without the flag.
2. **`bff/` module contents** -- `main.go` (re-mirror the *current* engine
   `main.go` + one blank import), `integrations/<product>/plugin.go` (Provider +
   `RegisterPluginForContract` + optional `RegisterRoutingRule`),
   `import_smoke_test.go`, `go.mod` (+ `replace`), `Dockerfile` (single bff
   image, two-tree context).
3. **Template `.gitignore`** -- add the `go.work` line (block already present).
4. **Template `ci.yml`** -- `bff` path-filter output + `bff` build/vet/test lane
   (sibling engine at `ENGINE_REF`, `GOWORK=off`, fail-hard clone) + `bff` in
   `ci-required` + generalize the digest gate to product-registry-digest /
   engine-registry-exempt. All inert for no-Go products.
5. **Template `Makefile`** -- a `bff/`-guarded build+k3d-import of
   `<product>-bff:local` in `make up`/`make dev` (shipped inert; only fires when
   `bff/` exists), so the local stack runs the product bff.
6. **Deploy overlays** -- the `images:` re-pin story (local tag / staging-prod
   digest placeholder) + one activation-checklist line per overlay.
7. **Docs** -- a stamped-product `CLAUDE.md`/`ONBOARDING.md` note on the bff
   inner loop; link this design.
8. **Resolve the open questions** (section 7) against the forcing product --
   especially leaf-node Go (Q1) and SDK demand (Q5).
