# =============================================================================
# Product stack Makefile -- the local k3d/ArgoCD lifecycle for this product.
# =============================================================================
#
# This file is OPERATIONAL: it reads product identity from product.env and stays
# byte-identical to the template, so a later `git merge template/main` never
# conflicts here. There are NO product-name tokens in this file.
#
# The composition is TWO ArgoCD Applications (see
# ../memql/docs/public/operate/downstream-stacks.md): the ENGINE Application
# (memql-local, owned by the engine repo) brings up the shared mesh; the PRODUCT
# Application (<product>-local, this repo's deploy/k8s/overlays/local) adds the
# product's own bff head (mounting the DSL bundle), the SPA, and the front door.
# The product repo does NOT copy the engine's k3d scripts -- it invokes them,
# passing the documented overrides.

# Product identity (written by scripts/init.sh; absent in the raw template).
-include product.env

ENGINE       ?= ../memql
# One shared local k3d cluster (the engine creates it, the product joins it).
# Overridable, but it is threaded through EVERY placement step below -- the
# engine bring-up, the bundle import, the SPA build/import, and the product App
# registration -- so `make up CLUSTER=x` builds ONE coherent stack on cluster x
# instead of silently splitting it across two (C5).
CLUSTER      ?= memql
NAMESPACE    ?= memql
# k3d LB ports fixed at cluster-create time; 50051 = the product bff raw gRPC.
EXTRA_PORTS  ?= 50051:50051
BUNDLE_IMAGE ?= $(PRODUCT)-dsl-bundle:local
REVISION      = $(shell git rev-parse --abbrev-ref HEAD)
# ArgoCD repo URL. The Application tracks THIS repo by URL, so derive it from the
# actual `origin` remote rather than assuming the GitHub repo is named exactly
# <product> (it need not be). Fall back to the org/product convention only when
# there is no origin yet, and warn at `up` time so a wrong-name pin is visible
# instead of silently pointing ArgoCD at a repo that does not exist (C12).
ORIGIN_URL   := $(shell git remote get-url origin 2>/dev/null)
REPO_URL     ?= $(if $(ORIGIN_URL),$(ORIGIN_URL),https://github.com/$(PRODUCT_ORG)/$(PRODUCT).git)
IMPORT        = bash $(ENGINE)/scripts/k3d/import-image.sh

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Guards
# -----------------------------------------------------------------------------

.PHONY: require-env
require-env:
	@test -f product.env || { echo "ERROR: product.env not found -- run scripts/init.sh first (see README)."; exit 1; }
	@test -n "$(PRODUCT)"     || { echo "ERROR: PRODUCT is empty in product.env"; exit 1; }
	@test -n "$(PRODUCT_ORG)" || { echo "ERROR: PRODUCT_ORG is empty in product.env"; exit 1; }
	@test -d "$(ENGINE)"      || { echo "ERROR: engine checkout not found at $(ENGINE) -- clone it as a sibling (see README)."; exit 1; }

# -----------------------------------------------------------------------------
# Stack lifecycle
# -----------------------------------------------------------------------------

.PHONY: up
## Bring up the whole local stack: engine mesh + this product (bff + SPA + DSL).
up: require-env
	@test -n "$(ORIGIN_URL)" || echo "WARN: no 'origin' remote; ArgoCD repo-url falls back to $(REPO_URL) -- push this repo and confirm the URL matches, or ArgoCD will track a repo that may not exist (C12)."
	@echo "==> [1/4] engine bring-up (cluster + ArgoCD + secrets + engine Application)"
	$(MAKE) -C $(ENGINE) up EXTRA_PORTS=$(EXTRA_PORTS) CLUSTER=$(CLUSTER)
	@echo "==> [2/4] build + import the product DSL bundle image"
	docker build -f deploy/Dockerfile.bundle -t $(BUNDLE_IMAGE) .
	$(IMPORT) --image=$(BUNDLE_IMAGE) --cluster=$(CLUSTER) --dryRun=false
	@echo "==> [3/4] build + import the product SPA image"
	$(MAKE) -C client image CLUSTER=$(CLUSTER)
	@echo "==> [4/4] register the product ArgoCD Application ($(PRODUCT)-local)"
	MEMQL_K3D_REPO_TOKEN=$${MEMQL_K3D_REPO_TOKEN:-$$(gh auth token 2>/dev/null)} \
	bash $(ENGINE)/scripts/k3d/up.sh \
		--cluster=$(CLUSTER) \
		--app-name=$(PRODUCT)-local \
		--app-project=$(PRODUCT) \
		--project-manifest=$(CURDIR)/deploy/argocd/project.yaml \
		--repo-url=$(REPO_URL) \
		--revision=$(REVISION) \
		--overlay-path=deploy/k8s/overlays/local \
		--no-secrets
	@echo "Stack up. Front door: https://app.$(DOMAIN) (SPA), https://bff.$(DOMAIN) (bff)."

.PHONY: dev
## Rebuild the DSL bundle and re-mount it on the product's bff (no cluster rebuild).
dev: require-env
	docker build -f deploy/Dockerfile.bundle -t $(BUNDLE_IMAGE) .
	$(IMPORT) --image=$(BUNDLE_IMAGE) --cluster=$(CLUSTER) --dryRun=false
	kubectl rollout restart -n $(NAMESPACE) deploy -l memql/product-dsl=true
	kubectl rollout status  -n $(NAMESPACE) deploy -l memql/product-dsl=true --timeout=180s

.PHONY: status
## Report the product Application + mesh status (delegates to the engine).
status: require-env
	$(MAKE) -C $(ENGINE) status APP_NAME=$(PRODUCT)-local CLUSTER=$(CLUSTER)

.PHONY: down
## Tear down the whole local cluster (engine + product share it).
down:
	$(MAKE) -C $(ENGINE) down CLUSTER=$(CLUSTER)

# -----------------------------------------------------------------------------
# Build / validate (no cluster)
# -----------------------------------------------------------------------------

.PHONY: bundle
## Build the data-only DSL bundle image from dsl/.
bundle: require-env
	docker build -f deploy/Dockerfile.bundle -t $(BUNDLE_IMAGE) .

.PHONY: render
## Render every kustomize overlay (the deploy CI gate, offline).
render:
	@for o in local staging prod; do \
		echo "==> render deploy/k8s/overlays/$$o"; \
		kubectl kustomize deploy/k8s/overlays/$$o >/dev/null || exit 1; \
	done
	@echo "all overlays render."

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

.PHONY: help
help:
	@echo ""
	@echo "Product stack ($(if $(PRODUCT),$(PRODUCT),<uninitialized -- run scripts/init.sh>))"
	@echo ""
	@echo "  make up        Bring up engine + product (bff + SPA + DSL) on local k3d"
	@echo "  make dev       Rebuild the DSL bundle and re-mount it on the bff"
	@echo "  make status    Product Application + mesh status"
	@echo "  make down      Tear down the local cluster"
	@echo "  make bundle    Build the DSL bundle image only"
	@echo "  make render    Render all kustomize overlays (offline)"
	@echo ""
	@echo "Client dev loop lives in client/ (make -C client dev | image)."
	@echo ""
