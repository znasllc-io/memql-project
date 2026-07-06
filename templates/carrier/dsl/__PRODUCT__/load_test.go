package dsltree

import (
	"os"
	"testing"

	"github.com/znasllc-io/memql/component/memql/dslimports"
)

// TestDSLTreeLoads runs the engine's dslimports.Load pipeline over this
// product's DSL namespace, asserting every construct (concepts / builtins /
// tools / automations) parses and resolves -- the same load the engine runs at
// boot. It reads the on-disk tree rooted at the parent (dsl/), which carries the
// __PRODUCT__/ namespace directory, so the file-top `use __PRODUCT__.builtins`
// imports resolve. A regression in any .memql file fails this test under the
// standard `go test ./...`.
func TestDSLTreeLoads(t *testing.T) {
	tree, err := dslimports.Load(os.DirFS(".."))
	if err != nil {
		t.Fatalf("dslimports.Load over the product DSL tree failed:\n%v", err)
	}
	if len(tree.Files) == 0 {
		t.Fatal("dslimports.Load loaded zero files -- expected the __PRODUCT__ namespace")
	}
}
