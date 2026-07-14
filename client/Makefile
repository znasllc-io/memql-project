# =============================================================================
# Client Makefile -- the SPA dev loop for this product.
# =============================================================================
#
# OPERATIONAL: byte-identical to the template, reads product.env; no
# product-name tokens. It owns only the CLIENT dev loop (Vite dev server +
# the SPA image build/import/roll). The STACK lifecycle (engine + cluster +
# ArgoCD) lives in the ROOT Makefile -- `make -C .. up | dev | status | down`.

# Product identity (written by scripts/init.sh; absent in the raw template).
-include ../product.env

NPM := npm
# The bff's entry on the local front door (traefik TLS on 443;
# bff.$(DOMAIN) -> 127.0.0.1). Vite proxies /memql here in dev.
MEMQL_HTTP_URL ?= https://bff.$(DOMAIN)

.DEFAULT_GOAL := help

# =============================================================================
# DEVELOPMENT
# =============================================================================

.PHONY: dev dev-frontend image build typecheck lint up status down

## Start the Vite dev server (proxies /memql to the bff; the dev-server port is
## set by the client's vite config). The backend cluster must already be up --
## `make -C .. up` brings it up.
dev:
	MEMQL_HTTP_URL=$(MEMQL_HTTP_URL) $(NPM) run dev

## Alias for `dev` -- the lean client ships a frontend-only dev server.
dev-frontend: dev

## Build the SPA image from this checkout, import it into k3d, and roll the
## in-cluster SPA Deployment. Invoked by the root `make up`.
image:
	@bash scripts/dev/build-image.sh

# =============================================================================
# BUILD / CHECK
# =============================================================================

## Production build (TypeScript check + Vite bundle).
build:
	$(NPM) run build

## Type-check only (tsc --noEmit).
typecheck:
	$(NPM) run typecheck

## Lint (the bare-ids ESLint contract).
lint:
	$(NPM) run lint

# =============================================================================
# STACK DELEGATION (the root Makefile owns the cluster)
# =============================================================================

## Bring up the whole local stack (delegates to the root Makefile).
up:
	$(MAKE) -C .. up

## Product Application + mesh status (delegates to the root Makefile).
status:
	$(MAKE) -C .. status

## Tear down the local cluster (delegates to the root Makefile).
down:
	$(MAKE) -C .. down

# =============================================================================
# HELP
# =============================================================================

.PHONY: help
help:
	@echo ""
	@echo "$(if $(PRODUCT),$(PRODUCT),<product>) client"
	@echo ""
	@echo "Client dev loop:"
	@echo "  make dev         Vite dev server (port per vite config; cluster must be up)"
	@echo "  make image       Build + import + roll the in-cluster SPA image"
	@echo "  make build       Production build (tsc + vite)"
	@echo "  make typecheck   tsc --noEmit"
	@echo "  make lint        bare-ids ESLint contract"
	@echo ""
	@echo "Stack (delegates to the root Makefile):"
	@echo "  make up | status | down"
	@echo ""
