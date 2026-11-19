# Product DSL

Put product-owned domains under `dsl/<domain>/`, with each domain's own
`memql.toml`. The engine's embedded domains do not belong in this directory.

A client-only package may ship no domains. Remove the starter domain and keep
this file: it preserves `dsl/` for the legacy bundle image's `COPY dsl /bundle`.
The DSL check then reports that there are no product domains and skips the
engine fetch and lint. Once a domain exists, the full root passes through the
engine-parity linter. A misplaced `.memql`, `memql.toml` or `namespace.pin` at
the root is an error, not a client-only package.

Deployables discovers domains from subdirectories. This root documentation is
not a domain and does not add DSL to the cluster.
