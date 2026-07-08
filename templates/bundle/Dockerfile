# syntax=docker/dockerfile:1
#
# __PRODUCT__ DSL bundle -- a data-only image. NO Go, NO build step.
#
# Platform consolidation (memql#2472): a product ships its DSL as this tiny
# image. The engine's `dsl-bundle` kustomize component runs it as an
# init-container that copies /bundle into a shared volume the product-agnostic
# engine mesh nodes read at MEMQL_DSL_PATH -- so a plain engine image runs this
# product's DSL with zero compiled-in product code.
#
# busybox (not scratch) because the init-container invokes `cp` to populate the
# shared volume. The whole "build" is copying text -- seconds, no matrix, no
# carrier-base. Tag + digest-pin it in deploy/k8s/overlays/<env> alongside the
# engine version + client digest.
FROM busybox:1.36
COPY dsl /bundle
