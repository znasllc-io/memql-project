module github.com/__PRODUCT_ORG__/__PRODUCT__-carrier

go 1.26.1

// The engine is consumed as a sibling checkout via the replace below. With the
// replace present Go reads ../memql directly and never fetches, so the require
// version is cosmetic -- it only has to be a syntactically valid module version.
// We therefore use the canonical local-replace pseudo-version here rather than
// the human-facing engine pin (__ENGINE_VERSION__), which bootstrap resolves to
// a git ref (a tag like v0.12.4, or "main") that is NOT always a valid go.mod
// version. The engine pin is recorded in VERSIONING.md and the deploy overlays
// (image tags / the kustomize base ?ref=), where a git ref is the right form.
require github.com/znasllc-io/memql v0.0.0-00010101000000-000000000000

// Local-workspace build. Required in three places:
//   - local dev under the workspace go.work (edits in ../memql build through),
//   - the hermetic Dockerfile release build (COPYs both trees, builds against
//     the sibling so it never needs proxy access to the private engine repo),
//   - CI that checks out the engine as a sibling.
// Because the replace points at a local directory, go.sum carries no engine
// hash (Go reads the dir, not the proxy). Run `go mod tidy` after cloning the
// engine sibling to populate go.sum for the engine's transitive deps.
replace github.com/znasllc-io/memql => ../memql
