# Onboarding -- the __PRODUCT__ workspace

A guide to the sibling repos in this workspace, how they fit together, and
how to make changes that cross repo boundaries without breaking CI.

> Everything lives as **siblings under this workspace root** and is tied
> together by a Go workspace (`go.work`) + `replace` dependency links.
> `scripts/bootstrap.sh` produces this layout; if a checkout is missing,
> the cross-repo tooling won't resolve.

---

## The repos

| Repo | Remote | Stack | Role |
|---|---|---|---|
| `memql` | `znasllc-io/memql` | Go + MemQL DSL | The shared engine: time-series memory graph DB, AI integration, cluster nodes, **and** the SDK generator + runtime core. Product-agnostic -- never edit it for product work. |
| `__PRODUCT__-carrier` | `__PRODUCT_ORG__/__PRODUCT__-carrier` | Go | Backend-for-frontend. Owns the product's concepts (`dsl/__PRODUCT__/`), integrations, deploy/release estate, and **generates `@__PRODUCT_ORG__/__PRODUCT__-sdk`** from `core DSL ∪ product DSL`. |
| `__PRODUCT__-client` | `__PRODUCT_ORG__/__PRODUCT__-client` | React + TS + Vite | The SPA. Talks to the backend **only** through the generated typed SDK (`conn.query.*`, `conn.subscriptions.*`, voice/audio). |
| `memql-cockpit` | `znasllc-io/memql-cockpit` | Go (TUI) | Terminal-native IDE + ops console for clusters; also the worker runtime (`cockpit worker run`). |

Each repo has a `CLAUDE.md` at its root -- read those for domain detail.
This guide is the cross-repo map.

---

## The SDK architecture (read this first)

"The SDK" is **three concerns**, each owned by what it's coupled to:

1. **Generator** (coupled to the DSL grammar) -> lives in **memql**
   (`sdk/gen`). Walks `.memql` files and emits typed methods. Shared by
   every carrier.
2. **Runtime core** `@znasllc-io/memql-sdk-core` (coupled to the
   `/memql/ws` wire protocol) -> lives in **memql** (`sdk/ts`). The
   `QueryClient`, `Connection`, subscriptions, voice/audio. Hand-written,
   client-agnostic.
3. **Generated typed surface** `@__PRODUCT_ORG__/__PRODUCT__-sdk`
   (coupled to a concept set) -> produced by the **carrier**
   (`__PRODUCT__-carrier/sdk/ts`). The `conn.query.queryX({...})` /
   `mutationX({...})` methods, layered onto the core via TypeScript
   `declare module` augmentation.

The client depends on `@__PRODUCT_ORG__/__PRODUCT__-sdk`, which re-exports
the core.

### How the typed surface is generated

`make sdk-gen` in the **carrier** runs the generator over two roots -- the
core DSL (resolved from the sibling `../memql`) and `dsl/__PRODUCT__` --
and writes `sdk/ts/src/generated/generated_{queries,mutations,logics,builtins}.ts`.
Constructs emit a typed method automatically:

- `query` / `mutation` / `logic` -> always emitted.
- `builtin` (`@executor` Go-backed capabilities) -> emitted **only** if
  marked `@sdk` (most builtins are internal and stay off the client
  surface).

memql also generates its own **Go** client (`sdk/go/client`) via its own
`make sdk-gen`.

### SDK consumption (GitHub Packages)

Both packages publish to **GitHub Packages** (npm.pkg.github.com). The
client's `.npmrc` maps the `@znasllc-io` and `@__PRODUCT_ORG__` scopes to
GitHub Packages and authenticates via `NODE_AUTH_TOKEN`; `package.json`
pins the SDK by version. After a carrier SDK release, bump the pin in the
client and `npm install`.

For local cross-repo iteration before a publish, the carrier's
`sdk/ts/dist` can be linked in temporarily -- but the committed state
always consumes the published package.

---

## Local setup

```bash
# All repos checked out as siblings in the workspace root
# (scripts/bootstrap.sh does this for you).
go work sync                       # Go side

# The local stack: k3d + ArgoCD, staging parity (THE blessed run path).
# Prerequisites: docker, k3d, kubectl, mkcert (brew install k3d kubectl mkcert)
cd __PRODUCT__-carrier
make up          # cluster + ArgoCD + secrets + images, wait healthy
make dev         # inner loop after code changes (single node: make dev NODE=bff)
make status      # mesh litmus: unique MEMQL_NODE_ID per pod
make down        # tear down

# The front door serves https://identity.__DOMAIN__ /
# https://bff.__DOMAIN__ / https://app.__DOMAIN__ (portless TLS,
# mkcert wildcard). Never use localhost URLs.

# The client dev servers:
cd ../__PRODUCT__-client && npm install
make dev
```

Multi-node is the default runtime everywhere: for cross-node mesh work
use `make up SERVERS=2` + `make scale N=2` in the carrier.

---

## The cross-repo change workflow (the important part)

A change to the typed surface usually touches **all three** SDK repos in a
**strict order**, because the carrier's drift-gate CI checks out memql
`main`:

```
1. memql        -- change the DSL / generator. `make sdk-gen` to refresh the
                  Go client. PR -> merge queue -> main.
2. carrier      -- `make sdk-gen` (now reads the updated memql main),
                  `make sdk-gen-check` clean. PR -> merge.
3. client       -- consume the new typed methods. typecheck + build. PR -> merge.
```

**Why the order is non-negotiable:** the carrier's SDK drift-check
workflow checks out `znasllc-io/memql` at `main` and regenerates. If you
commit a regenerated carrier SDK whose source DSL isn't on memql `main`
yet, the gate regenerates a *different* surface and fails. Land memql
first. Don't open all three PRs at once expecting them to merge together.

### Verify gates per repo

| Repo | Gate |
|---|---|
| memql | `go build ./...`, `go test ./...` (incl. the dsl conformance suites), `make sdk-gen-check`. PRs merge via the merge queue; CodeQL (`Analyze (go)`) is required and takes ~3 min. |
| carrier | `make sdk-gen-check` (drift gate), scan (gitleaks/govulncheck). |
| client | typecheck + build (`make check`). |

---

## Conventions

- **Branch / PR.** Feature branch -> PR -> merge -> delete branch -> pull
  main -> prune.
- **Issues.** Track work with a GitHub issue; land changes via PRs linked
  to it. Multiple sessions may run against this tree in parallel --
  assign the issue to yourself before starting.
- **Staging (memql).** Stage by **explicit path** (`git add <file>`),
  never `git add -A` -- other sessions' untracked files must not get
  swept in.
- **Pre-1.0 everywhere.** No backwards-compat shims, no deprecation
  windows. When a contract changes, fix both sides at once and delete the
  old path.
- **Frontend ping.** A memql or carrier change that alters a wire
  contract the client depends on must be called out in the commit/PR so
  it can be relayed to the frontend side.
- **Ids.** Clients use BARE ids only; canonicalization is server-side
  (see `memql/docs/public/concepts/identifiers.md`). Never compose,
  parse, or compare `v1:...`-prefixed ids in client code.
- **Docs/code tone.** No emojis in code, comments, commit messages, or
  docs.

---

## Gotchas

- **The engine repo is read-only for product work.** If a product need
  seems to require an engine edit, it's a missing seam -- file an engine
  issue; the template test ("could a second product plug in without
  editing the engine repo?") gates every seam.
- **`make sdk-gen` -> "no constructs found" / can't resolve the memql
  module.** The generator needs the sibling `../memql` (via `replace` /
  `go.work`). Confirm the checkouts are siblings and `go work sync` has
  run.
- **Carrier CI: SDK drift gate red.** The committed
  `sdk/ts/src/generated` doesn't match what the generator produces from
  memql `main`. Almost always: you regenerated before the source DSL
  landed on memql `main`, or you didn't regenerate at all. **Land memql
  first.**
- **ArgoCD needs the branch PUSHED.** The local cluster's product
  Application tracks the carrier repo by URL; ArgoCD cannot read
  local-only branches. A private carrier repo needs
  `MEMQL_K3D_REPO_TOKEN=$(gh auth token)` on `make up`.
- **memql PR stuck at `BLOCKED` with everything green.** CodeQL
  (`Analyze (go)`) is still running -- required, ~3 min. Poll
  `gh pr checks <pr>`.

---

## Where to dig deeper

- `memql/CLAUDE.md` -- engine architecture, DSL dependency tree, node
  types, authoring rules, the gRPC-first endpoint policy.
- `memql/docs/public/operate/downstream-stacks.md` -- the carrier
  contract this workspace implements.
- `memql/docs/public/build/plugin-sdk.md` + `building-a-pack.md` -- the
  pack extension contract the carrier targets.
- `__PRODUCT__-carrier/CLAUDE.md` -- product concepts, deploy/release
  estate.
- `__PRODUCT__-client/CLAUDE.md` -- SPA architecture and SDK consumption.
