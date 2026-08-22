# `clients/` -- this product's surfaces

A **client** is an application that a person or another system points at this
product's memQL stack: a landing page, an SPA, a mobile app, a kiosk, a game.
`clients/<name>/` is where one lives, and the directory is **plural on
purpose**.

A product is a **DSL bundle plus one or more client surfaces**. One operator
serving one customer may ship a marketing landing page, an operator SPA, and an
embedded game -- three surfaces, one DSL, one bff head, one release. The
singular `client/` this template used to ship encoded a one-surface-per-repo
assumption that memQL-as-a-platform does not have. This mirrors the convention
the engine established for its own surfaces (`memql/clients/README.md`, engine
issue #3314), so the two repos read the same way.

The starter ships exactly one: [`web/`](web) -- a Vite + React + TypeScript
SPA. Grow it into the product, or add siblings next to it.

## What one surface owns

Everything a surface needs is inside its own directory, and everything outside
it is derived from the directory **name**:

| Thing | Value | Set where |
|---|---|---|
| npm package | `<product>-<name>` | `clients/<name>/package.json` |
| local image | `<product>-<name>:local` | derived from the directory name |
| published image | `<registry>/<product>-<name>` | derived; digest-pinned per release |
| Deployment + Service | `<product>-<name>` | `deploy/k8s/base/clients-<name>.yaml` |
| release lockfile key | `<name>` | `deploy/releases/<release>.yaml` |

`clients/<name>/Makefile` and `clients/<name>/scripts/dev/build-image.sh` read
the surface name from `$(notdir $(CURDIR))` / `basename`, so they are
**byte-identical across surfaces and across products**. Nothing enumerates the
surfaces by hand: the root `Makefile`, CI, and `publish-images.yml` all
discover them by listing this directory.

## Adding a second surface

```bash
cp -R clients/web clients/game
rm -rf clients/game/node_modules clients/game/dist
```

Then, mechanically:

1. **`clients/game/package.json`** -- set `"name": "<product>-game"`.
2. **`deploy/k8s/base/clients-game.yaml`** -- copy `clients-web.yaml`, replace
   `<product>-web` with `<product>-game` throughout. Add it to
   `deploy/k8s/base/kustomization.yaml`'s `resources:`.
3. **Each overlay** (`local`, `cloud`) -- add the image pin
   (`- name: <product>-game`, `newTag: local` locally, `digest:` in `cloud`)
   and a route to the new Service in `front-door.yaml` / `public-entry.yaml`.
   A second surface is a second hostname (`game.<domain>`) or a second path
   prefix; pick one and route it.
4. Nothing else. `make up`, `make dev`, CI's client lane, `publish-images.yml`,
   and the release lockfile pick the surface up from the directory listing.

Step 2 and 3 are manual because kustomize does not template: a Deployment and
an ingress route are per-surface facts, not a loop. Everything that *can* be
derived, is.

## Rules

1. **A surface is an application, not a library.** `"private": true`, no
   `publishConfig`. Whether the lockfile is committed is the product's call
   (the starter ignores it; a real app should commit one).
2. **Bare ids, everywhere.** Canonicalization is server-side. No surface
   composes, parses, or compares `v1:`-prefixed ids; the ESLint config in each
   surface enforces it. See the engine's
   `docs/public/concepts/identifiers.md`.
3. **Dial the origin you were served from.** A surface reaches the bff through
   the front door it was served behind, over `/memql` relative -- not a
   hardcoded cross-origin host. It removes a whole class of CORS and
   mis-pointing bugs, and it is why the bff's `SERVER_ALLOWED_ORIGINS` can stay
   a concrete, non-wildcard value.
4. **Share through the SDK, not through a sibling import.** Two surfaces that
   need the same typed query surface both consume the product SDK
   (`@<org>/<product>-sdk`); `clients/game` never imports from `clients/web`.
   Cross-surface imports break the per-surface image build (each surface's
   Docker context is its own directory).
5. **One surface, one image, one digest.** A release pins every surface it
   ships by `@sha256`. Do not fold two surfaces into one image.
