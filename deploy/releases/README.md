# Release lockfiles

Each `deploy/releases/<release>.yaml` pins ONE product release: the two product
images (the DSL bundle + the client SPA) by `@sha256` digest, plus the engine
ref the release ships against. A release is the immutable unit of promotion.

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
  client:
    image: "ghcr.io/<org>/<product>-client"
    digest: "sha256:<64hex>"
```

## The promote flow (tag -> digest -> lockfile -> pin -> apply)

1. **Publish** -- dispatch `.github/workflows/publish-images.yml`; it builds both
   product images, pushes them to `REGISTRY` under an immutable tag, and prints
   each `@sha256` digest (plus a copy-paste lockfile) in the run summary.
2. **Assemble** -- `scripts/release/assemble-lockfile.sh --release=<id>
   --bundle-digest=... --client-digest=...` writes `deploy/releases/<id>.yaml`
   and self-validates it.
3. **Gate** -- `scripts/release/coherence-check.sh --lockfile=deploy/releases/<id>.yaml`
   fails on any floating (non-digest) pin or missing component.
4. **Pin** -- `scripts/release/promote.sh --release=<id> --to-env=staging`
   copies the lockfile digests into the staging overlay (no rebuild), then
   re-asserts the rendered overlay matches the lockfile.
5. **Apply** -- commit the pinned overlay; the ArgoCD Application reconciles it.
6. **Promote** -- once staging is validated, `promote.sh --release=<id>
   --to-env=prod` copies the SAME digests into prod: prod runs the exact bytes
   staging ran.

The scripts are registry-agnostic and read product identity from `product.env`,
so this flow is byte-identical across every product stamped from the template.
