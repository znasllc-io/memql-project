// sdk-gen generates the @__PRODUCT_ORG__/__PRODUCT__-sdk typed TypeScript
// surface from `core DSL ∪ the __PRODUCT__ DSL`, layering it onto the
// @znasllc-io/memql-sdk-core runtime via declare-module augmentation.
//
// It imports the memQL generator package (github.com/znasllc-io/memql/sdk/gen)
// and runs it over two roots: the core DSL (resolved from the memql module's
// on-disk location, so it works with the local `replace => ../memql`, a go.work
// workspace, and the module cache alike) and this repo's dsl/__PRODUCT__ tree.
//
// Run from the repo root:
//
//	go run ./scripts/sdk-gen           # regenerate sdk/ts/src/generated
//	go run ./scripts/sdk-gen --check   # drift gate (CI)
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/znasllc-io/memql/sdk/gen"
)

// corePackage is the npm specifier the generated TS imports QueryClient / types
// from and augments via `declare module`. The product SDK ships the generated
// surface as a separate package that depends on the core, so the augmentation
// targets the core package, not a relative path.
const corePackage = "@znasllc-io/memql-sdk-core"

// carrierModule is this repo's Go module path. We resolve its on-disk dir by
// EXPLICIT module path rather than `go list -m` with no args: a Go workspace
// (go.work) in a parent dir makes the no-arg form list every workspace module,
// not just this one.
const carrierModule = "github.com/__PRODUCT_ORG__/__PRODUCT__-carrier"

// moduleDir returns the on-disk directory of a Go module, resolved by its
// explicit module path. Honors the local replace directive, a go.work
// workspace, and the module cache transparently.
func moduleDir(module string) (string, error) {
	args := []string{"list", "-m", "-f", "{{.Dir}}"}
	if module != "" {
		args = append(args, module)
	}
	out, err := exec.Command("go", args...).Output()
	if err != nil {
		return "", fmt.Errorf("go %s: %w", strings.Join(args, " "), err)
	}
	dir := strings.TrimSpace(string(out))
	if dir == "" {
		return "", fmt.Errorf("empty module dir for %q", module)
	}
	return dir, nil
}

func main() {
	check := flag.Bool("check", false, "exit non-zero if the generated SDK is out of date (CI drift gate)")
	flag.Parse()

	carrierDir, err := moduleDir(carrierModule)
	if err != nil {
		fail(fmt.Errorf("resolve this module (%s): %w", carrierModule, err))
	}
	coreDir, err := moduleDir("github.com/znasllc-io/memql")
	if err != nil {
		fail(fmt.Errorf("resolve memql module (is `replace => ../memql` present, or memql checked out?): %w", err))
	}

	coreDSL := filepath.Join(coreDir, "dsl")
	productDSL := filepath.Join(carrierDir, "dsl", "__PRODUCT__")
	tsOut := filepath.Join(carrierDir, "sdk", "ts", "src", "generated")

	res, err := gen.Generate(gen.Options{
		Roots:        []string{coreDSL, productDSL},
		TSOut:        tsOut,
		TSImportFrom: corePackage,
		Check:        *check,
	})
	if err != nil {
		if *check && res != nil && len(res.Drift) > 0 {
			for _, p := range res.Drift {
				fmt.Fprintf(os.Stderr, "drift: %s\n", p)
			}
			fmt.Fprintln(os.Stderr, "\n__PRODUCT__-sdk is out of date. Run `go run ./scripts/sdk-gen` and commit the result.")
			os.Exit(1)
		}
		fail(err)
	}

	if *check {
		fmt.Println("__PRODUCT__-sdk: no drift")
		return
	}
	for _, p := range res.Wrote {
		fmt.Printf("wrote %s\n", p)
	}
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "sdk-gen: %v\n", err)
	os.Exit(1)
}
