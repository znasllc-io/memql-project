// Package pack is the __PRODUCT__ product's Go integration surface. It hosts the
// three registration primitives a memQL pack uses, all from init():
//
//   - dsl.RegisterTree("__PRODUCT__", ...) -- via the blank import of the DSL
//     package below, whose own init() mounts the embedded .memql subtree.
//   - memql.RegisterPluginForContract(...) -- registers the Go
//     IntegrationProvider against the Plugin SDK contract version, so a stale
//     pack fails loudly at startup instead of silently mis-binding.
//   - node.RegisterRoutingRule(...) -- broadcasts this pack's graph events so
//     they cross node boundaries in cluster mode.
//
// The package is named `pack` (not the product slug) so it is a valid Go
// identifier for any product name. See docs/public/build/building-a-pack.md in
// the engine repo for the full pack model; this is a minimal starter to grow.
package pack

import (
	"context"
	"encoding/json"
	"fmt"

	memorynodes "github.com/znasllc-io/memql/component/database/memory-nodes"
	"github.com/znasllc-io/memql/component/memql"
	"github.com/znasllc-io/memql/component/node"

	// Blank import: triggers the DSL package init(), which mounts the
	// __PRODUCT__ .memql tree into the engine. Without this the carrier boots
	// with zero product concepts / tools / automations.
	_ "github.com/__PRODUCT_ORG__/__PRODUCT__-carrier/dsl/__PRODUCT__"
)

// integrationName is the IntegrationProvider's stable identifier and the middle
// segment of every capability FQN: "integration.<integrationName>.<capability>".
// It MUST match the @executor namespace used in dsl/__PRODUCT__/builtins.memql.
const integrationName = "__PRODUCT__"

// ContractVersion is the Plugin SDK contract version this pack was built
// against. Pinned to the constant the pack compiled with, so the loader fails
// loudly if this pack is linked into an engine with an incompatible contract.
const ContractVersion = memql.PluginContractVersion

// Provider is the pack's IntegrationProvider. It exposes DSL-callable Go
// capabilities; the one starter capability ("composeGreeting") backs the
// builtin in dsl/__PRODUCT__/builtins.memql via its @executor FQN. Grow this
// with the product's real Go-backed capabilities.
type Provider struct{}

// IntegrationName implements memql.IntegrationProvider.
func (p *Provider) IntegrationName() string { return integrationName }

// Capabilities implements memql.IntegrationProvider. Each capability's Name
// combines with IntegrationName() into its FQN, e.g.
// "integration.__PRODUCT__.composeGreeting".
func (p *Provider) Capabilities() []memql.IntegrationCapability {
	return []memql.IntegrationCapability{
		{
			Name:        "composeGreeting",
			Description: "Compose a greeting string for a user name. The starter pack's single Go-backed capability -- replace with the product's own.",
			Handler:     p.composeGreeting,
			ArgsSchema: map[string]string{
				"userName": "string (required) - name to greet",
			},
		},
	}
}

// composeGreeting is the starter capability handler. It returns one object node
// carrying the composed greeting, demonstrating the DSL-builtin -> Go-capability
// wire end to end.
func (p *Provider) composeGreeting(_ context.Context, args map[string]any, _ int) ([]memorynodes.MemoryNode, error) {
	userName, _ := args["userName"].(string)
	if userName == "" {
		return nil, fmt.Errorf("__PRODUCT__.composeGreeting requires userName")
	}
	payload, _ := json.Marshal(map[string]any{
		"greeting":    fmt.Sprintf("Hello, %s -- from the __PRODUCT__ pack.", userName),
		"integration": integrationName,
	})
	return []memorynodes.MemoryNode{{
		ID:      fmt.Sprintf("__PRODUCT__-greeting:%s", userName),
		Concept: "integration:__PRODUCT__:greeting",
		Type:    memorynodes.NodeTypeObject,
		Payload: payload,
	}}, nil
}

// NewProvider is the memql.PluginFactory the app bootstrap calls after engine
// init. A real pack plucks DB getters, providers, and resolvers off pctx here;
// this starter needs none. Return (nil, nil) to opt out when deps are missing.
func NewProvider(pctx memql.PluginContext) (memql.IntegrationProvider, error) {
	_ = pctx
	return &Provider{}, nil
}

// init registers the Go plugin (contract-versioned) and the product's graph
// event routing rules. The DSL tree is mounted by the blank-imported DSL
// package's own init(). Registration is unconditional -- every carrier-built
// node type carries the product pack (matching the reference carrier). Move an
// init() into a build-tag-gated file if a registration must be scoped to a
// subset of node types.
func init() {
	memql.RegisterPluginForContract(integrationName, ContractVersion, NewProvider)

	// Broadcast this pack's graph events so every peer hears create/update/
	// delete in cluster mode. Without a routing rule a cross-node event-bus
	// pub/sub silently dies in the mesh.
	for _, verb := range []string{"created", "updated", "deleted"} {
		node.RegisterRoutingRule(node.RoutingRule{
			Pattern:    fmt.Sprintf("graph.node.%s.v1:__PRODUCT__:*", verb),
			TargetType: "",
		})
	}
}
