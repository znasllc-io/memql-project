package app

// Smoke test for tagged-module consumption.
//
// This package blank-imports
// github.com/__PRODUCT_ORG__/__PRODUCT__-carrier/integrations/__PRODUCT__,
// which is exactly how the carrier binary wires the product pack into the
// engine. If the public import surface ever stops compiling, or an init() hook
// panics on load, this test fails -- catching breakage before an image is
// built, without needing the full carrier binary.

import "testing"

func TestImportSurfaceLoads(t *testing.T) {
	// Reaching this point means the blank import in plugins___PRODUCT__.go (and
	// the transitive integration + DSL package init() functions) compiled and
	// ran without panicking. Nothing further to assert.
}
