# __PRODUCT__-client

The __PRODUCT__ product frontend: a Vite + React + TypeScript **app shell**
stamped from the memQL project template. It rides the memQL engine mesh through
the product's bff front door and demonstrates the platform's **bare-ids client
contract** end to end.

## What's in the shell

A lean-but-real starting point (grow it into the product):

- **Identity login** — magic-link against `https://identity.__DOMAIN__`
  (`src/lib/auth/identity.ts`), a session context (`src/context/Session.tsx`),
  and a protected-route guard (`src/App.tsx`).
- **One typed query round-trip** — `src/pages/Home.tsx` calls a named query
  function over the memQL client and renders bare-id rows.
- **One subscription example** — `src/pages/Live.tsx` subscribes to a concept's
  CDC stream using **generated topic constants** (`src/generated/concepts.ts`),
  never a hand-written `graph.node…` / `v1:` string.
- **The bare-ids contract, enforced** — `eslint.config.js` bans `v1:`-prefixed
  id literals and `.split(':')` / `.lastIndexOf(':')` id surgery. Rows that mix
  concepts are keyed by `(concept, id)` (`nodeKey`), never by id alone.

## Bare ids (non-negotiable)

Canonicalization is **server-side only**. This client passes and receives **bare
short slugs** everywhere; it never composes, parses, or compares canonical `v1:`
ids. The one place canonical ids appear is `src/generated/concepts.ts` — the
machine-generated DSL source of truth — and the ESLint config excludes it. See
the engine's `docs/public/concepts/identifiers.md`.

## SDK resolution (read before wiring the published SDK)

The production memQL SDK for this product is **`@__PRODUCT_ORG__/__PRODUCT__-sdk`**
(published to GitHub Packages). The carrier's `make sdk-gen` generates it from
`core DSL ∪ the product DSL`; it re-exports `@znasllc-io/memql-sdk-core` (the
shared runtime) plus the product's typed query/mutation surface and the
generated bare-ids concept/topic constants.

**At stamp time that package does not exist yet** (a freshly-stamped product has
published nothing), so this shell is deliberately **self-contained**: it ships a
thin local memQL client (`src/lib/memql/client.ts`) and a local generated
concepts module (`src/generated/concepts.ts`, the sdk-gen A3 shape). This is why
`npm install && npm run build` work immediately, with **no `NODE_AUTH_TOKEN` and
no dependency on an unpublished package**.

**To wire the real SDK once the product publishes it:**

1. In the sibling carrier, run `make sdk-gen` (regenerates `sdk/ts`), then
   publish it (its `__PRODUCT__-sdk-publish` workflow) — or, before publishing,
   resolve it locally: `npm install ../__PRODUCT__-carrier/sdk/ts` (a `file:`
   link) or `npm link @__PRODUCT_ORG__/__PRODUCT__-sdk` against the carrier's
   built `sdk/ts`.
2. Export `NODE_AUTH_TOKEN` (a GitHub token with `read:packages` for the
   `@__PRODUCT_ORG__` + `@znasllc-io` scopes — `.npmrc` points both there).
3. Replace `src/lib/memql/client.ts` with the SDK's `Connection` / `QueryClient`
   and import the concept/topic constants from `@__PRODUCT_ORG__/__PRODUCT__-sdk`
   instead of `src/generated/concepts.ts`. The wire shape (bare-id args → bare-id
   rows; `topicFor` / `filterFor` for subscriptions) is identical, so the swap is
   mechanical.

## Local development

Prerequisites: Node ≥ 20, and the sibling checkouts `../memql` (engine) +
`../__PRODUCT__-carrier` (carrier), as laid out by the workspace bootstrap.

```bash
npm install

# Bring up the full local stack: the k3d cluster (engine mesh + carrier bff head,
# via the sibling carrier) + this SPA served in-cluster.
make up

# Attached HMR inner loop (Vite on :8080, proxies /memql to https://bff.__DOMAIN__):
make dev
```

`make dev` serves the app at http://localhost:8080; the front door is
`https://app.__DOMAIN__`. See `Makefile` for the full target list and
`scripts/dev/` for the cluster delegation.

## Build

```bash
npm run typecheck   # tsc --noEmit
npm run build       # tsc --noEmit && vite build -> dist/
npm run lint        # the bare-ids ESLint contract
```
