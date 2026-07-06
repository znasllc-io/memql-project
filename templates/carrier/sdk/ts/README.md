# @__PRODUCT_ORG__/__PRODUCT__-sdk

The typed memQL SDK for the __PRODUCT__ web app. It is the
`@znasllc-io/memql-sdk-core` runtime (connection, dispatcher,
subscriptions, voice) plus the **generated** __PRODUCT__ query/mutation/
logic surface, produced from `core DSL + this repo's dsl/__PRODUCT__` tree.

__PRODUCT__ depends on this single package: the runtime and the typed
concept methods come from one import.

## Install

Published to GitHub Packages. Point both scopes at the GitHub registry in
an `.npmrc` (this package depends on `@znasllc-io/memql-sdk-core`):

```
@__PRODUCT_ORG__:registry=https://npm.pkg.github.com
@znasllc-io:registry=https://npm.pkg.github.com
```

then:

```
npm install @__PRODUCT_ORG__/__PRODUCT__-sdk
```

## Usage

```ts
import { Connection } from "@__PRODUCT_ORG__/__PRODUCT__-sdk";

const conn = await Connection.dial({
  endpoint: "wss://staging.host/memql/ws",
  auth: { bearer: jwt },
});

const spaces = await conn.query.queryActiveSpaces({});   // typed, generated
await conn.query.mutationCreateSpace({ partitionId, name });
const unsub = conn.subscriptions.subscribe(
  "graph.node.created.*.v1:cognition:utterance",
  (e) => render(e),
);
```

Voice (push-to-talk) lives on a subpath:

```ts
import { pushToTalk } from "@__PRODUCT_ORG__/__PRODUCT__-sdk/voice";
```

## Generation

The typed surface under `src/generated/` is generated -- DO NOT EDIT it by
hand. Regenerate after any DSL change (core or __PRODUCT__):

```
make sdk-gen        # go run ./scripts/sdk-gen
make sdk-gen-check  # drift gate (CI)
```

The generator (memQL's `sdk/gen`) walks `core DSL + dsl/__PRODUCT__`,
deterministically merges the constructs, and emits methods that augment
the core `QueryClient` via `declare module "@znasllc-io/memql-sdk-core"`.

## Build

```
npm run build      # tsc -> dist
npm run typecheck  # tsc --noEmit
```

ESM only, strict TypeScript, browser-targeted.
