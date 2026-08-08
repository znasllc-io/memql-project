# Release lockfiles

Each `deploy/releases/<release>.yaml` pins ONE product release: every product
image -- the DSL bundle plus **one per client surface** (`clients/` is plural;
see [`../../clients/README.md`](../../clients/README.md)) -- by `@sha256`
digest, plus the engine ref the release ships against. A release is the
immutable unit of promotion.

The component set is not hardcoded anywhere: `publish-images.yml` discovers the
surfaces by listing `clients/`, and `coherence-check.sh` / `promote.sh` read the
component keys back out of the lockfile. A product with three surfaces has four
components and all four are gated.

Lockfiles are **immutable** -- a new release gets a new file; never edit one in
place. Rollback is `git revert` + re-pin, not an in-place digest swap.

## Shape

```yaml
release: "<id>"                       # the immutable tag publish-images.yml built
registry: "ghcr.io/<org>"             # REGISTRY from product.env
engineRef: "<x.y.z>"                  # ENGINE_REF the release ships against
components:
  dsl-bundle:
    image: "ghcr.io/<org>/<product>-dsl-bundle"
    digest: "sha256:<64hex>"
  web:                                # one block PER CLIENT SURFACE,
    image: "ghcr.io/<org>/<product>-web"   #   keyed by the clients/<name> dir
    digest: "sha256:<64hex>"
```

## The promote flow (tag -> digest -> lockfile -> pin -> apply)

1. **Publish** -- dispatch `.github/workflows/publish-images.yml`; it builds both
   product images, pushes them to `REGISTRY` under an immutable tag, and prints
   each `@sha256` digest (plus a copy-paste lockfile) in the run summary.
2. **Assemble** -- `scripts/release/assemble-lockfile.sh --release=<id>
   --bundle-digest=... --client-digests=web=sha256:...[,game=sha256:...]`
   writes `deploy/releases/<id>.yaml` and self-validates it. The publish run's
   summary prints this command fully filled in.
3. **Gate** -- `scripts/release/coherence-check.sh --lockfile=deploy/releases/<id>.yaml`
   fails on any floating (non-digest) pin or missing component.
4. **Pin** -- `scripts/release/promote.sh --release=<id> --to-env=staging`
   copies every lockfile digest into the staging overlay (no rebuild), then
   re-asserts the rendered overlay matches the lockfile. A component the overlay
   does not pin is a refusal with the overlay untouched -- so adding a surface
   without pinning it in an overlay fails loudly here.
5. **Apply** -- commit the pinned overlay; the ArgoCD Application reconciles it.
6. **Promote** -- once staging is validated, `promote.sh --release=<id>
   --to-env=prod` copies the SAME digests into prod: prod runs the exact bytes
   staging ran.

The scripts are registry-agnostic and read product identity from `product.env`,
so this flow is byte-identical across every product stamped from the template.

## Client build-time configuration caveat (exact-bytes scope)

The exact-bytes promise ("prod runs the same bytes staging ran") holds
**unconditionally for the DSL bundle** -- it is data-only and carries no
per-environment configuration.

**Client surfaces are different**: each `clients/<name>/Dockerfile` bakes two
URLs at build time -- `VITE_MEMQL_HTTP_URL` (the bff front door) and
`VITE_IDENTITY_BASE_URL` (the magic-link + JWKS host). `publish-images.yml`
exposes them as the optional `vite_memql_http_url` / `vite_identity_base_url`
dispatch inputs, applied to **every** surface in the run:

- **Left blank (the starter default):** the Dockerfile defaults hold, each
  surface is environment-agnostic, and its digest promotes staging -> prod
  exactly, same as the bundle.
- **Set to real per-environment URLs:** those digests are **environment
  specific**. Promoting them from staging to prod would ship a surface that
  talks to the staging backend from prod. In that case do **not** promote the
  client digests across environments that use different URLs: build once per
  environment (dispatch `publish-images.yml` with that env's URLs) and pin each
  overlay to its own digests. A single release lockfile carries ONE digest per
  surface, so genuinely distinct per-env URLs do not fit the
  one-lockfile-per-release model as-is.

The real fix that restores the unconditional exact-bytes promise for the client
surfaces is **runtime configuration** (serve the URLs from the environment at
container start instead of baking them at build time), tracked as follow-up.
Until then, keeping the two URLs environment-agnostic -- or serving both
environments from the same public hostnames -- is what keeps one digest per
surface correct across a promote.
