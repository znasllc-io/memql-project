package app

// Anchor file for __PRODUCT__ product registrations. Blank-importing the
// integrations package runs its init() hooks (memql.RegisterPluginForContract,
// node.RegisterRoutingRule, dsl.RegisterTree via the transitive DSL import) for
// every carrier-built node type. If a registration ever needs to be scoped to a
// specific node-type binary, move the corresponding init() into a
// build-tag-gated file inside integrations/__PRODUCT__/.
import (
	_ "github.com/__PRODUCT_ORG__/__PRODUCT__-carrier/integrations/__PRODUCT__"
)
