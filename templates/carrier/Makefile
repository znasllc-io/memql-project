GO ?= go

# =============================================================================
# LOCAL STACK (engine mesh + carrier nodes + the __PRODUCT__ bff head)
# =============================================================================
# This repo reuses the memql engine's k3d tooling via the downstream-stack
# contract (engine: docs/public/operate/downstream-stacks.md). `make up` runs
# the engine bring-up with THIS repo as the carrier (bff/cognition/agent/
# planner/workbench images build from ./Dockerfile), then registers the
# __PRODUCT__-local ArgoCD Application (deploy/k8s/overlays/local -- the bff
# head). Prereqs: the memql sibling checkout at ../memql, gh authed (if this
# repo is private, ArgoCD needs a token), and the current branch PUSHED
# (ArgoCD cannot read local-only branches).

ENGINE ?= ../memql
CARRIER_FLAGS := CARRIER_REPO=$(CURDIR) CARRIER_NODES=bff,cognition,agent,planner,workbench
STACK_PORTS := EXTRA_PORTS=50051:50051,8086:8086

.PHONY: up up-refresh dev scale status down secrets register-app

## Fresh bring-up of the full local stack: engine cluster (with carrier-built
## node images from this repo) + the __PRODUCT__-local Application.
##   make up
##   make up SERVERS=2 AGENTS=1   # multi-node mesh
up:
	$(MAKE) -C $(ENGINE) up $(CARRIER_FLAGS) $(STACK_PORTS)
	bash scripts/dev/register-app.sh

## Clean slate: nuke + repave the cluster (fresh DB), then the same bring-up.
up-refresh:
	$(MAKE) -C $(ENGINE) up-refresh $(CARRIER_FLAGS) $(STACK_PORTS)
	bash scripts/dev/register-app.sh

## (Re-)register the __PRODUCT__-local Application on a running cluster.
register-app:
	bash scripts/dev/register-app.sh

## Inner loop: rebuild carrier image(s) from this repo, import, restart.
##   make dev                # all node types
##   make dev NODE=bff       # one node type
dev:
	$(MAKE) -C $(ENGINE) dev $(CARRIER_FLAGS) $(if $(NODE),NODE=$(NODE)) $(if $(PULL_INFRA),PULL_INFRA=$(PULL_INFRA))

## Scale app Deployments (2 = staging parity), report mesh status, seed
## secrets, tear down -- straight delegations to the engine tooling.
scale:
	$(MAKE) -C $(ENGINE) scale N=$(N)
status:
	$(MAKE) -C $(ENGINE) status APP_NAME=__PRODUCT__-local
secrets:
	$(MAKE) -C $(ENGINE) secrets
down:
	$(MAKE) -C $(ENGINE) down $(if $(PURGE),PURGE=$(PURGE))

# =============================================================================
# SDK (typed TypeScript surface generated from core DSL + the __PRODUCT__ DSL)
# =============================================================================

.PHONY: sdk-gen sdk-gen-check sdk-ts-install sdk-ts-typecheck

## Regenerate the __PRODUCT__ SDK typed surface (sdk/ts/src/generated) from core
## DSL + dsl/__PRODUCT__. Imports the engine's generator (sdk/gen) and resolves
## the core DSL from the memql module on disk (local replace / go.work / module
## cache). Re-run after any DSL change in either tree.
sdk-gen:
	$(GO) run ./scripts/sdk-gen

## CI drift gate: regenerate + diff against the checked-in tree. Fails if the
## SDK is stale vs the DSL. Needs the memql module available (local replace,
## go.work, or a sibling checkout in CI).
sdk-gen-check:
	$(GO) run ./scripts/sdk-gen --check

## Install the __PRODUCT__ SDK dev dependencies. Requires the @znasllc-io scope
## pointed at GitHub Packages (the package depends on @znasllc-io/memql-sdk-core).
sdk-ts-install:
	cd sdk/ts && npm install --no-audit --no-fund

## Typecheck the __PRODUCT__ SDK (tsc --noEmit). Requires sdk-ts-install.
sdk-ts-typecheck:
	cd sdk/ts && npm run typecheck

# =============================================================================
# RELEASE / DEPLOY ESTATE (product-owned; wraps scripts/{release,deploy})
# =============================================================================
# `make release` cuts an immutable carrier image; the deploy targets wrap the
# per-env provisioning + apply scripts. See each script's --help. Engine-generic
# capability backends stay engine-side, so some scripts skip-with-warning when
# an engine-only helper is absent from this checkout.

.PHONY: release publish-releases deploy-setup blob-provision db-provision \
        livekit-provision deploy-aks deploy-rollback release-staging \
        reset-staging staging-db-reset smoke-staging

## Cut an immutable memql-bff-__PRODUCT__:X.Y.Z CARRIER image from the VERSION
## file + short git SHA. The image bundles the memQL engine (pinned in go.mod)
## with the __PRODUCT__ DSL + integrations; its build context spans both memql/
## and this repo per the Dockerfile's `replace ../memql`. Pass-through via ARGS.
release:
	bash scripts/release/release.sh $(ARGS)

## Publish the GitHub Releases matching the release lockfiles (releases/).
publish-releases:
	@bash scripts/release/publish-releases.sh \
		$${REPO:+--repo=$$REPO} $${VERSION:+--version=$$VERSION} $${DRY_RUN:+--dry-run} $(ARGS)

## Bootstrap the cloud deployment foundation for ENV (staging|production).
deploy-setup:
	@bash .claude/scripts/deploy-setup.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Provision a dedicated blob storage account + container for ENV.
blob-provision:
	@bash scripts/deploy/blob-provision.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Provision the managed DB for ENV and wire its DSN into the per-env vault.
db-provision:
	@bash scripts/deploy/tiger-provision.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Provision the self-hosted LiveKit shared-secret pair into the per-env vault.
livekit-provision:
	@bash scripts/deploy/livekit-provision.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Apply the AKS manifests for ENV to the current kubectl context.
deploy-aks:
	@bash scripts/deploy/aks-apply.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Roll the mesh back to a previous good release (git revert of the pinned overlay).
deploy-rollback:
	@bash scripts/deploy/aks-rollback.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## ONE idempotent command to take staging to a VALIDATED release.
release-staging:
	@bash scripts/deploy/staging-release.sh --env=$${ENV:-staging} \
		$${VERSION:+--version=$$VERSION} $${VERIFY:+--verify} $${SKIP_BUILD:+--skip-build} \
		$${NO_SMOKE:+--no-smoke} $${NO_GATE:+--no-gate} $${DRY_RUN:+--dry-run} $(ARGS)

## ONE idempotent command to RESET staging to a fresh, FULLY-USABLE state.
reset-staging:
	@bash scripts/deploy/staging-reset.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## DESTRUCTIVE, MANUAL staging DB reset (auth-coherent). NEVER part of a deploy.
staging-db-reset:
	@bash scripts/deploy/staging-db-reset.sh --env=$${ENV:-staging} $${DRY_RUN:+--dry-run} $(ARGS)

## Repeatable end-to-end smoke test against the LIVE staging front door.
smoke-staging:
	@bash scripts/deploy/staging-smoke-test.sh $(ARGS)
