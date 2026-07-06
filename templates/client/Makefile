# =============================================================================
# __PRODUCT__ Makefile
# =============================================================================
#
# Build and development automation for the __PRODUCT__ client.
# Run `make help` for available targets.

# =============================================================================
# CONFIGURATION
# =============================================================================

VERSION := $(shell cat VERSION 2>/dev/null || echo "0.0.0-0")
NPM := npm

# =============================================================================
# DEVELOPMENT
# =============================================================================

.PHONY: dev dev-frontend up up-refresh dev-refresh dev-fresh

# The bff's entry on the local front door (traefik TLS on 443;
# bff.__DOMAIN__ -> 127.0.0.1). Vite proxies /memql here.
MEMQL_HTTP_URL ?= https://bff.__DOMAIN__

## Start the frontend dev server (Vite on :8080, proxies /memql to the
## bff). Assumes the backend cluster is already up (`make up` brings it up).
dev:
	MEMQL_HTTP_URL=$(MEMQL_HTTP_URL) $(NPM) run dev

## Alias for `dev` -- the lean client ships a frontend-only dev server.
dev-frontend: dev

## Bring up EVERYTHING, fully containerized and DETACHED: the local k3d
## cluster (memql engine mesh + carrier-built nodes + the bff head, via
## the sibling __PRODUCT__-carrier repo's make up), then the SPA built
## from THIS checkout, imported into k3d, and served in-cluster at
## https://app.__DOMAIN__. Nothing stays attached to the terminal;
## the attached HMR inner loop is `make dev`.
up:
	@bash scripts/dev/stack.sh up
	@bash scripts/dev/build-image.sh

## Clean slate: nuke + repave the cluster (fresh DB) via the sibling
## repo's make up-refresh, then rebuild + serve the SPA in-cluster.
up-refresh:
	@bash scripts/dev/stack.sh up-refresh
	@bash scripts/dev/build-image.sh

## Aliases -- keep the dev-refresh / dev-fresh muscle memory working.
dev-refresh: up-refresh
dev-fresh: up-refresh

# =============================================================================
# BUILD
# =============================================================================

.PHONY: build

## Production build (TypeScript check + Vite bundle)
build:
	$(NPM) run build

# =============================================================================
# HELP
# =============================================================================

.PHONY: help
.DEFAULT_GOAL := help

## Show available targets
help:
	@echo ""
	@echo "__PRODUCT__ client $(VERSION)"
	@echo ""
	@echo "Development:"
	@echo "  make up                  Bring up EVERYTHING: k3d cluster (engine + carrier + bff) + in-cluster SPA"
	@echo "  make up-refresh          Clean slate: nuke + repave the cluster, then rebuild the SPA"
	@echo "  make dev                 Start the frontend dev server (Vite on :8080; cluster must be up)"
	@echo "  make dev-frontend        Alias for make dev"
	@echo ""
	@echo "Build:"
	@echo "  make build               Production build (tsc + vite)"
	@echo ""
	@echo "  make help                Show this help message"
	@echo ""
