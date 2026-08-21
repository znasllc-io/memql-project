# Release lockfiles

Each `deploy/releases/<release>.yaml` pins ONE product release: every product
image -- the DSL bundle plus **one per client surface** (`clients/` is plural;
see [`../../clients/README.md`](../../clients/README.md)) -- by `@sha256`
digest, plus the engine ref the release ships against. A release is the
immutable unit an overlay is pinned to.

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

## The pin flow (tag -> digest -> lockfile -> pin -> apply)

1. **Publish** -- dispatch `.github/workflows/publish-images.yml`; it builds
   every product image, pushes them to `REGISTRY` under an immutable tag, and
   prints each `@sha256` digest (plus a copy-paste lockfile) in the run summary.
2. **Assemble** -- `scripts/release/assemble-lockfile.sh --release=<id>
   --bundle-digest=... --client-digests=web=sha256:...[,game=sha256:...]`
   writes `deploy/releases/<id>.yaml` and self-validates it. The publish run's
   summary prints this command fully filled in.
3. **Gate** -- `scripts/release/coherence-check.sh --lockfile=deploy/releases/<id>.yaml`
   fails on any floating (non-digest) pin or missing component.
4. **Pin** -- `scripts/release/promote.sh --release=<id>` copies every lockfile
   digest into the cloud overlay (`deploy/k8s/overlays/cloud`; no rebuild), then
   re-asserts the rendered overlay matches the lockfile. A component the overlay
   does not pin is a refusal with the overlay untouched -- so adding a surface
   without pinning it in the overlay fails loudly here.
5. **Apply** -- commit the pinned overlay; the cloud ArgoCD Application
   (`deploy/argocd/apps/<product>-cloud.yaml`) reconciles it. The cluster runs
   the exact bytes CI built: the digest in the overlay is the digest the
   registry returned at push.

There is no promotion step after that. MemQL ships **one installation shape**
(engine epic [znasllc-io/memql#3943](https://github.com/znasllc-io/memql/issues/3943)):
`local` and `cloud` are two deploy targets of one shape, not two environments
of one install, so there is no staging overlay to validate on and no prod
overlay to promote into. A second environment is a **second instance** -- its
own cluster or at least its own ArgoCD, its own domain, its own database -- and
it is pinned the same way: `promote.sh --release=<id> --overlay=<its-overlay>`
when the instance lives in this repo as its own overlay directory (the engine's
`deploy/k8s/overlays/cloud-entry` is the worked example), or the same command
in its own repo. The `--to-env` flag that carried the retired environment axis
is gone, not aliased; `--overlay=local` is refused because the local overlay
pins mutable `:local` tags for k3d import, never digests.

The scripts are registry-agnostic and read product identity from `product.env`,
so this flow is byte-identical across every product stamped from the template.

## Client build-time configuration caveat (what one digest can serve)

The DSL bundle is data-only and carries no per-instance configuration: one
bundle digest serves every instance that ships the release.

**Client surfaces are different**: each `clients/<name>/Dockerfile` bakes two
URLs at build time -- `VITE_MEMQL_HTTP_URL` (the bff front door) and
`VITE_IDENTITY_BASE_URL` (the magic-link + JWKS host). `publish-images.yml`
exposes them as the optional `vite_memql_http_url` / `vite_identity_base_url`
dispatch inputs, applied to **every** surface in the run:

- **Left blank (the starter default):** the Dockerfile defaults hold, each
  surface is instance-agnostic, and one digest per surface serves any instance,
  same as the bundle.
- **Set to an instance's real URLs:** those digests are **instance specific** --
  they name that instance's hostnames. A second instance with its own domain
  needs its own client build (dispatch `publish-images.yml` with its URLs), its
  own lockfile and its own overlay pin; never copy a client digest that bakes
  another instance's hostnames into a second instance's overlay. A lockfile
  carries ONE digest per surface, so one lockfile describes one instance's
  release.

The real fix that lets one client digest serve every instance unconditionally
is **runtime configuration** (serve the URLs from the environment at container
start instead of baking them at build time), tracked as follow-up. Until then,
keeping the two URLs instance-agnostic is what keeps one digest per surface
correct across instances.
