// Package dsltree owns the __PRODUCT__ product's DSL tree. The .memql (+ any
// .tmpl) files in this directory are embedded into the carrier binary at
// compile time via //go:embed and mounted into the engine's unified DSL surface
// at boot via dsl.RegisterTree("__PRODUCT__", Tree()).
//
// The init() side-effect runs when any Go file in this package is imported
// (transitively, via the carrier binary's blank-import of
// integrations/__PRODUCT__). Without it the engine boots with zero __PRODUCT__
// concepts / tools / automations and the product's calls resolve to nothing.
//
// The package is named `dsltree` (not the product slug) so it is a valid Go
// identifier regardless of the product name -- the mount domain "__PRODUCT__"
// is a string, and the blank import is by path, so neither needs the package
// name to match the product.
package dsltree

import (
	"embed"
	"io/fs"

	memqldsl "github.com/znasllc-io/memql/dsl"
)

// Domain is the DSL namespace this pack owns. It must not collide with a core
// engine domain or another pack's domain -- dsl.RegisterTree validates this via
// dsl.ValidatePackDomain and panics on a collision.
const Domain = "__PRODUCT__"

// packFS holds every .memql (+ .tmpl) file under the __PRODUCT__ domain. The
// all: prefix matches the engine's embed convention so soft-disabled files
// (_-prefixed) get embedded too.
//
//go:embed all:*.memql
var packFS embed.FS

// Tree returns the embedded __PRODUCT__ DSL tree. Exposed so tooling (format /
// lint / SDK gen) can walk the same FS the engine sees at boot.
func Tree() fs.FS {
	return packFS
}

// init mounts the __PRODUCT__ tree under the "__PRODUCT__" domain in the
// engine's unified DSL surface. Runs at package import time.
func init() {
	memqldsl.RegisterTree(Domain, Tree())
}
