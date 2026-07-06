# Versioning

This module — the **__PRODUCT__ BFF carrier** (`github.com/__PRODUCT_ORG__/__PRODUCT__-carrier`) —
follows [Semantic Versioning](https://semver.org/) and is published as a
semver-tagged Go module.

## Source of truth

The **git tag** is the authoritative version. A tag `vMAJOR.MINOR.PATCH` is
cut from `main` after the corresponding PR merges; the Go module proxy and
`go get` resolve releases from those tags.

The `VERSION` file in the repo root tracks the current baseline in plain
semver (no build/epoch suffix) so tooling and docs have a single textual
reference. It is kept in lock-step with the most recent release tag.

## Baseline: 0.1.0

The carrier is reset to **0.1.0** as the platform versioning baseline,
superseding the interim `v0.2.0`. We stay in **v0.x** through pre-release:
Go only requires the `/vN` module-path suffix at v2 and above, so v0.x keeps
the import path clean (`github.com/__PRODUCT_ORG__/__PRODUCT__-carrier`, no
`/v2`).

**1.0.0** is reserved for the public **beta** of the platform, at which point
the carrier joins the "platform train" cut described in the hub doc below.

## The pin chain

The __PRODUCT__ BFF carrier sits in the middle of a three-link pin chain. Each
link pins the one below it to an immutable, reproducible reference:

```
__PRODUCT__
   │  pins the CARRIER version (an image tag), via its
   │  carrier-version deploy file (__PRODUCT_ORG__/__PRODUCT__#140)
   ▼
memql-bff-__PRODUCT__:X.Y.Z        ← this carrier image (make release)
   │  pins the memQL ENGINE version, via go.mod:
   │      require github.com/znasllc-io/memql v__ENGINE_VERSION__
   ▼
github.com/znasllc-io/memql @ v__ENGINE_VERSION__   ← the engine, by git tag
```

- **__PRODUCT__ → carrier:** __PRODUCT__ pins a `memql-bff-__PRODUCT__:X.Y.Z`
  *image tag*, not a Go module. The tag is cut by `make release`
  (`scripts/release/release.sh`), which builds an immutable image from the
  `VERSION` file (0.1.0) + the short git SHA and refuses to overwrite an
  existing tag (`--allow-overwrite` to force). The SHA is stamped as the
  `org.opencontainers.image.revision` OCI label so every tag is traceable
  back to a commit.
- **carrier → engine:** this carrier's `go.mod` pins memQL with
  `require github.com/znasllc-io/memql v__ENGINE_VERSION__`. That tagged version is the
  authoritative release pin; `go list -m github.com/znasllc-io/memql`
  reports it (see "memQL engine pin" below for the local-dev `replace`
  caveat).

The carrier image's build context spans both `memql/` and
`memql-bff-__PRODUCT__/` (per the `replace` directive in `go.mod`), which is
why the release Dockerfile + `make release` build from the workspace parent.

## memQL engine pin (`go.mod`)

`go.mod` carries two coupled lines for the engine dependency:

```
require github.com/znasllc-io/memql v__ENGINE_VERSION__   // the release pin (authoritative)
replace github.com/znasllc-io/memql => ../memql   // source location for dev/CI/Docker
```

- The **require** is the pinned engine version — the single source of truth
  for which memQL release this carrier ships against. `go.mod` records the
  tag; a `GOWORK=off go list -m github.com/znasllc-io/memql` resolves it to
  `v__ENGINE_VERSION__`. The `scripts/release` test `TestMemqlPinResolves` guards this so
  the pin can never silently regress to a floating pseudo-version.
- The **replace** redirects the *source location* (not the version) to the
  sibling `../memql` checkout. It is needed for local workspace dev, the
  hermetic carrier Dockerfile build (which COPYs both trees), and the
  `govulncheck` CI job (the default `GITHUB_TOKEN` cannot fetch the private
  `znasllc-io/memql` over the module proxy). When the engine *is* fetched
  from the remote, the global
  `url."git@github.com:".insteadOf "https://github.com/"` git config pulls
  the private tag over SSH.

To bump the engine: edit the `require` version, run
`GOWORK=off go mod tidy`, and verify `GOWORK=off go build ./...` plus
`go test ./scripts/release/`.

## Compatibility

The authoritative cross-component compatibility matrix — which carrier
version pairs with which memQL engine/protocol version — lives in the
**hub `COMPATIBILITY.md`** in the memQL repo:

- <https://github.com/znasllc-io/memql/blob/main/COMPATIBILITY.md>

## Cutting a release

Tags are cut from `main` after the relevant PR merges:

```bash
git checkout main && git pull --ff-only
# pick the next semver tag (bump patch/minor/major as appropriate)
git tag v0.1.0
git push origin v0.1.0
```

Use an annotated tag if you want a release message:
`git tag -a v0.1.0 -m "release v0.1.0"`.
