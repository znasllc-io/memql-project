# memql-project

GitHub template for a **memQL product workspace**: the repo constellation
that runs a product on the shared, product-agnostic
[memQL engine](https://github.com/znasllc-io/memql).

A product is a **DSL bundle + a client** on the shared, product-agnostic engine
— **no product Go and no per-product node images** in the common case (platform
consolidation, [memql#2472](https://github.com/znasllc-io/memql/issues/2472)).
The checkout directory of this repo is the **workspace root**. After stamping,
it holds these sibling checkouts (each its own git repository, ignored by this
one):

```
<workspace-root>/                 this repo, stamped from the template
├── memql/                        the shared engine (cloned, never edited per-product)
├── __PRODUCT__-bundle/           the product DSL (.memql) + tiny data-only bundle
│                                 image + the one deploy overlay. NO go.work,
│                                 NO Go module -- delivered to the engine at
│                                 runtime via MEMQL_DSL_PATH.
├── __PRODUCT__-client/           the product frontend (SPA)
└── memql-cockpit/                terminal IDE / ops console (cloned)
```

A "bff" is just a plain engine `bff` node fronting the product (mounting its
bundle) — a deploy concern, not code. A release is `{engine version, bundle
digest, client digest}` in one overlay in the bundle repo.

**Bespoke Go (rare):** a product that genuinely needs Go the engine can't
provide generically stamps the **carrier** variant instead
(`scripts/bootstrap.sh ... --go-module`) — a thin `bff/` Go module + a
`go.work` consolidating it with the engine. Prefer DSL first.

The engine never names a product; products plug in through the documented
seams (`memql/docs/public/operate/downstream-stacks.md` and the
`MEMQL_DSL_PATH` runtime-delivery mechanism). The acceptance bar for the whole
pattern: **a second product boots a full stack with zero engine-repo edits.**

## Quickstart

1. Click **Use this template** to create your workspace repo, then clone it.
2. Stamp the workspace (non-interactive; see `--help` for all params):

   ```bash
   scripts/bootstrap.sh --product=acme --product-org=acme-io
   ```

   This clones the engine and cockpit, stamps the **bundle** and client repos
   from `templates/` (add `--go-module` for the carrier variant), substitutes
   the tokens below across the workspace docs, and — only for the carrier
   variant — regenerates `go.work` + the carrier's `go.sum`. Add
   `--create-repos=github` to also
   create + push private GitHub repos for the stamped product repos.

   Alternatively run `memql-cockpit setup project` for the interactive
   wizard driving the same script.

3. Bring up the local stack (k3d + ArgoCD, staging parity):

   ```bash
   cd __PRODUCT__-carrier && make up
   ```

   The front door serves `https://identity.__DOMAIN__`,
   `https://bff.__DOMAIN__`, and `https://app.__DOMAIN__`.

4. Read [ONBOARDING.md](ONBOARDING.md) for the cross-repo development
   workflow (the SDK three-tier architecture, the strict engine-first
   landing order, per-repo CI gates).

## Template tokens

| Token | Meaning | Example |
|---|---|---|
| `__PRODUCT__` | product name (lowercase slug) | `acme` |
| `__PRODUCT_ORG__` | GitHub org/user owning the product repos | `acme-io` |
| `__DOMAIN__` | local front-door domain (mkcert wildcard) | `local.znas.io` |
| `__ENGINE_VERSION__` | engine ref pinned at stamp time | `v0.12.4` |

`scripts/bootstrap.sh` substitutes every token in file contents and
file/directory names; CI greps stamped output for leftovers (zero
tolerance). The engine org (`znasllc-io`) stays literal.

## Repository layout (pre-stamp)

| Path | Purpose |
|---|---|
| `go.work` | committed workspace manifest (bootstrap regenerates it) |
| `ONBOARDING.md` | the cross-repo developer guide the stamp personalizes |
| `scripts/bootstrap.sh` | the stamper -- a capability script (JSON envelope on stdout, honest exit codes) |
| `scripts/lib/capability.sh` | vendored capability-script runtime from the engine |
| `templates/carrier/` | parameterized carrier repo payload (82 artifacts) |
| `templates/client/` | parameterized client repo payload (full app shell) |

Note on the shared local domain: two stamped products default to the same
`__DOMAIN__` front-door hostnames, so run one local stack at a time or
stamp each product with its own `--domain`.
