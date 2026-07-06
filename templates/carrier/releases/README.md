# releases/

This directory holds one **immutable release lockfile per release**, named
`<version>.yaml` (e.g. `0.1.0.yaml`). Each lockfile pins the exact set of
container image digests that make up a deployable release of the product
stack — the engine node images (built from `github.com/znasllc-io/memql`),
the carrier image (`memql-bff-__PRODUCT__`), and the client/SPA image
(`__PRODUCT__`).

## How a lockfile is produced

Lockfiles are assembled by
[`scripts/release/assemble-lockfile.sh`](../scripts/release/assemble-lockfile.sh).
Each repo's CI emits the digest of the image it built; the assembly step
(the release-lockfile workflow, or an operator) collects those per-component
digests and writes `releases/<version>.yaml`. The digests are resolved from
ACR (`acrmemql.azurecr.io`) by tag. The lockfile is then PR'd, and the
`scripts/release/coherence-check.sh` gate validates it before it can be
promoted.

Once written, a lockfile is **never edited** — a new release gets a new
`<version>.yaml`. This makes every release reproducible: the digests are
content-addressed, so the exact bits that were validated are the exact bits
that get deployed.

## Fields

| Field | Meaning |
|-------|---------|
| `version` | The product release version (this lockfile's own name). |
| `engineVersion` | The `github.com/znasllc-io/memql` engine version this release was built against. |
| `gate` | The validation gate depth that certified this release. |
| `components.<name>.repo` | The GitHub `owner/repo` the image was built from. |
| `components.<name>.digest` | The immutable `sha256:` image digest. |
| `components.<name>.builtAgainstEngine` | (carrier + client only) the engine version the component was compiled against. |

## Example

The single `0.1.0.yaml` in this directory is a **shape reference** — a
representative lockfile showing the expected structure. Real releases replace
its placeholder version tokens and digests with concrete values assembled by
`assemble-lockfile.sh`. Do not treat it as a deployable release.
