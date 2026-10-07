# Template and product pipeline coverage

The root `memql-package.yaml` declares this template's checks. During the first
stamp, `scripts/init.sh` copies `.template/memql-package.yaml` into the product
root, removes that consumed source, then substitutes the product identity.
Subsequent stamps preserve the owner's manifest changes. A dry run changes
neither recipe. This keeps template-only assertions out of generated products.

Both recipes use the engine's installed `runPipelineStages` MemQL automation
(engine PR #5883). Commands, event selection and timeouts are manifest policy;
the engine supplies scheduling, enforcement and reporting. Do not put a second
workflow dispatcher in a native helper. See the engine's
[integration boundary](https://github.com/znasllc-io/memql/blob/main/docs/public/build/integration-boundary.md).
Product recipes belong in `dsl/`; native code supplies protocol and host
operations that those recipes compose.

## Workflow inventory

All existing GitHub workflows remain enabled until installed qualification,
observation and required-check transition. The manifest alone does not enable
a GitHub App, grant repository access or authorize publishing.

| Existing workflow | Manifest coverage | Remaining qualification before retirement |
| --- | --- | --- |
| `ci.yml` | Product ShellCheck, capability contracts, client build/typecheck/lint/test, local/cloud render/digest gates and product DSL lint; template ShellCheck and capability contracts | Installed candidate checks and required-check identity. Product checks use full selection rather than legacy path-filter skips. |
| `template-ci.yml` | Make parse; complete `demo` and `demo-app` stamping assertions, token isolation, layout, DSL lint/migration/coexistence, renders/CORS, clients, repeat stamp and refused identity change; manifest replacement regression | Execute both matrix recipes on the pinned container. The separate stamped-DSL job's lint assertion is covered inside both matrix recipes. |
| `deployment-observer-tests.yml` | Observer Python tests and render | Installed check delivery. |
| `gitleaks.yml` | v8.30.1 current-tree PR scan and full-history push/merge-candidate/release scan; redacted report retained | Weekly trigger and installed full-history execution. |
| `publish-images.yml` | No publication equivalent declared | Manual registry/tag/build arguments, authorized image builds/push and coherent immutable release lockfile. |
| `engine-version-watch.yml` | No equivalent declared | Weekly/manual released-engine lookup and authorized bump PR creation. |
| `template-drift.yml` | No equivalent declared | Weekly/manual comparison with the selected upstream template revision. |

The common product recipe is shipped as data, not constructed in Go. The
stamper only copies that declared recipe; its existence check is mechanical
idempotency. The pipeline uses the pinned ARM64 toolchain, Go 1.26.6 and an
SHA-256-verified official ShellCheck 0.11.0 binary. Security still runs after
an earlier failure and cannot clear that failure.

## Local validation

`python3 -m unittest discover -s scripts/ci -p 'test_pipeline_stamping.py'`
proves first-stamp replacement, identifier substitution, consumed-artifact
removal, no mutation in a dry run, preservation of owner policy on repeat
stamps, and refusal of a changed identity without manifest mutation.

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
