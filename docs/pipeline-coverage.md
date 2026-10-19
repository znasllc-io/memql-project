# Template and product pipeline coverage

The root `memql-package.yaml` declares this template's checks. During the first
stamp, `scripts/init.sh` copies `.template/memql-package.yaml` into the product
root, removes that consumed source, then substitutes the product identity.
Subsequent stamps preserve the owner's manifest changes, including when a
template sync reintroduces the starter recipe. Other `.template/` assets remain
in place after the consumed recipe is removed. A dry run changes
neither recipe. This keeps template-only assertions out of generated products.

Both recipes use the engine's installed `runPipelineStages` MemQL automation
(engine PR #5883). Commands, event selection and timeouts are manifest policy;
the engine supplies scheduling, enforcement and reporting. Do not put a second
workflow dispatcher in a native helper. See the engine's
[integration boundary](https://github.com/znasllc-io/memql/blob/main/docs/public/build/integration-boundary.md).
Product recipes belong in `dsl/`; native code supplies protocol and host
operations that those recipes compose.

Both the template recipe and the generated product recipe require an engine
release containing [memql#5883](https://github.com/znasllc-io/memql/pull/5883)
(merge commit `82c37723251d016bca6a8589f50caed67e1dfbca`) or a later descendant
with those contracts. This is the minimum source revision, not a released
version number. Older strict package parsers reject `runAfterFailure` and
`memoryMiB`, including when analyzing a generated product for deployment.
Successful DSL lint against an older `ENGINE_REF` does not qualify the package
manifest or pipeline execution. Stamping preserves the chosen runtime pin;
install and qualify a compatible engine before analyzing, importing or enabling
either recipe. Keep this template change in draft until that prerequisite is
available to generated products.

## Workflow inventory

All existing GitHub workflows remain enabled until installed qualification,
observation and required-check transition. The manifest alone does not enable
a GitHub App, grant repository access or authorize publishing.

| Existing workflow | Manifest coverage | Remaining qualification before retirement |
| --- | --- | --- |
| `ci.yml` | Product ShellCheck, capability contracts, client build/typecheck/lint/test, local/cloud render/digest gates and product DSL lint; template ShellCheck and capability contracts | Installed candidate checks and required-check identity. Product checks use full selection rather than legacy path-filter skips. |
| `template-ci.yml` | Make parse; complete `demo` and `demo-app` stamping assertions, token isolation, layout, DSL lint/migration/coexistence, renders/CORS, clients, repeat stamp and refused identity change; manifest replacement regression | Execute both matrix recipes on the pinned container. The separate stamped-DSL job's lint assertion is covered inside both matrix recipes. |
| `deployment-observer-tests.yml` | Observer Python tests and render | Installed check delivery. |
| `gitleaks.yml` | v8.30.1 introduced-commit scan on PR/push/merge candidates; weekly and explicit manual full-history scans; redacted coverage receipts retained | Weekly trigger and installed full-history execution. |
| `publish-images.yml` | Declared release image builds for the bundle and every client surface; checked inventory prevents omissions | Installed builds, approved registry destinations, verified native publication receipts and immutable lockfile. |
| `engine-version-watch.yml` | Weekly/manual retained proposal and bounded native draft-PR writer | Weekly/manual released-engine lookup and authorized bump PR creation. |
| `template-drift.yml` | Weekly/manual native comparison with the selected upstream template revision; retained JSON report | Installed receipt before removing the old workflow. |

The common product recipe is shipped as data, not constructed in Go. The
stamper only copies that declared recipe before `product.env` exists; this is mechanical
idempotency. The pipeline uses the pinned AMD64 toolchain, Go 1.26.9 and an
SHA-256-verified official ShellCheck 0.11.0 binary. Security still runs after
an earlier failure and cannot clear that failure.

## Local validation

`python3 -m unittest discover -s scripts/ci -p 'test_pipeline_stamping.py'`
proves first-stamp replacement, identifier substitution, consumed-artifact
removal, no mutation in a dry run, preservation of owner policy on repeat
stamps even after the source is reintroduced, preservation of other template
assets, and refusal of a changed identity without manifest mutation.

Run the existing capability suite with
`python3 -m unittest discover -s scripts/ci -p 'test_capability_conformance.py'`.
Compile both manifests with the combined engine before enabling them. Keep
native platform qualification, triggers and publication evidence separate from
source checks; none of the latter prove a release was delivered.

Local command execution passed in the declared Linux ARM64 toolchain image:
capability contracts, ShellCheck, deployment-observer tests/render, and both
complete `demo`/`demo-app` matrix recipes. Both cases linted the stamped DSL,
checked migration/coexistence, rendered local/cloud overlays, built and linted
the client, and verified repeat-stamp and identity-refusal behavior. Current-tree
and full-history Gitleaks 8.30.1 also passed (77 historical commits).

## Current build-pool port

The recipe now selects Linux AMD64 and Go 1.26.9. Native host declarations
remain explicit. The daily schedule selects only opted-in stages; full-history
secret checks run weekly and on an explicit manual audit. Releases do not repeat
the full-history audit. PR, push and merge-candidate scans still cover every
introduced commit, including a secret added
and removed before the final tree. A missing predecessor falls back to full
history; an unreadable nonempty base fails. The bounded scanner and its
regressions are copied from the engine, preserving failure and coverage receipts.
These additions require an engine containing memql#6137's stage cadence; the
Cockpit SARIF delivery step also requires memql#6146. Historical results above
are not qualification of this rebased source or of installed execution.

An incremental scan first reads the actual parent identities in the retained
commit objects. When every ancestry path reaches the pinned base, those objects
prove the complete introduced-commit inventory, even if the excluded base is
outside a shallow checkout. The scanner retains that proof and scans every
introduced commit; Git's root diff at a shallow boundary includes the whole
tree, so a removed intermediate secret remains detectable. Replacement refs
are disabled for both inventory and scanning.

This avoids an unnecessary unauthenticated fetch from a private repository when
the checkout already contains every introduced commit. A missing intermediate
object, an ancestry path that does not reach the base, or a full-history audit
still requires the normal complete-history path. Failure to fetch that history
remains a failed scan; this optimization does not supply private-repository
credentials or qualify private full-history execution. See Git's
[shallow-repository contract](https://git-scm.com/docs/shallow).

## Product image releases

`VERSION` identifies the product's image set independently of `ENGINE_REF`.
Change it in the release PR, merge the checked source, and create the matching
immutable `vX.Y.Z` tag. Start its release in MemQL Pipelines. The declared
`images` stage builds `deploy/Dockerfile.bundle` and each `clients/*/Dockerfile`
on the bounded cloud pool for `linux/amd64`. Builders retain an OCI archive and
metadata in the Library; they have no registry publisher credential.

After adding or removing a client surface, run
`python3 scripts/ci/product-images.py --write`, review the marked stage, and
commit it with the surface change. Existing public build arguments remain in
that declaration. The required inventory check fails until every component is
represented and refuses a release tag that disagrees with `VERSION`. Template
checks validate `.template/memql-package.yaml`; stamped products validate their
root manifest.

Configure release-candidate sources to read the exact commit's `VERSION` and
select every `images.<component>` archive plus its metadata. Registry names,
credentials and immutable destination tags are operator-approved configuration.
Publish the approved candidate, require verified read-back receipts for every
component, then pass those registry digests to
`scripts/release/assemble-lockfile.sh`. Pin and merge that coherent lockfile
through the existing GitOps deployment path. A build receipt alone is not a
publication or deployment receipt.

A Dockerfile may opt into `githubReadToken: true` to mount the fixed
`github_read_token` BuildKit secret for **its own repository's contents**.
This requires the engine runtime shipped by memql#6200. It does not authorize
private npm packages or another repository. The starter's dependencies are
public and request no repository token. Do not substitute a writer credential
to satisfy a private dependency; configure the appropriate bounded reader.

Retire the legacy publisher after this complete native path has a retained
qualification receipt. Its remaining file does not authorize using Actions as
a fallback.

## Engine release proposals

The weekly `engine-proposal` stages require engine 0.30.0's native
`repositoryChange` contract. Do not activate this recipe on an older engine.
The producer reads published stable releases and changes only the literal
`ENGINE_REF` assignment. A repository-scoped reader token stays on that
repository's GitHub API paths. No shell sources `product.env`.

The operator must configure the recipe's named rule in
`MEMQL_PIPELINES_REPOSITORY_CHANGE_RULES` with this exact repository, mode
`propose`, branch prefix `engine-bump/`, and the single allowed path
`product.env`. The driver independently verifies the retained proposal and
current default branch before creating a draft PR. It does not merge or deploy;
reviewers must resolve and update image digests and qualify the resulting PR.
An existing proposal branch is preserved, including a deliberately closed PR.
Merging workflow retirement requires a retained receipt from the installed
native writer.

## Native template identity and harness comparison

The unstamped `.template/memql-package.yaml` is the setup marker. The first
stamp consumes it into the root product manifest. A later run preserves the
owner's recipe; a missing `product.env` after consumption refuses restamping,
even if a template sync restores the placeholder DSL directory. No setup check
depends on an Actions workflow file.

The weekly comparison inventories tracked scripts, setup documentation and the
native manifest. Product manifests are reported as stamped differences, since
applications and execution choices legitimately differ. Untracked caches and
the consumed template recipe cannot appear as product harness drift.
