# syntax=docker/dockerfile:1
#
# memQL BFF (__PRODUCT__) carrier-binary Dockerfile.
#
# Builds the bff binary that the memql-cluster docker-compose stack
# runs as the `bff` service. Differs from memql/docker/memql.Dockerfile
# in one shape-level way: the build context spans BOTH memql/ AND
# __PRODUCT__-carrier/ as sibling directories under the context
# root, because __PRODUCT__-carrier's go.mod has a
# `replace github.com/znasllc-io/memql => ../memql` directive that
# points at the local sibling for development. Docker's build context
# resolves the relative path the same way local `go build` does.
#
# Caller (docker compose) sets the build context to the parent of
# memql/ (= ~/projects/memql/ in local dev) and points dockerfile at
# this file:
#
#     build:
#       context: ../../   # from memql/docker/ -> workspace root
#       dockerfile: __PRODUCT__-carrier/Dockerfile
#
# memql#356 -- pre-this-Dockerfile, the bff service built from
# memql/docker/memql.Dockerfile, which produces a binary with no
# __PRODUCT__ DSL + no __PRODUCT__ integrations. The SPA's calls to
# querySystemConfig / mutationUpsertOnboarding / queryCanvasStatesForSpace
# / queryPrivateCanvasStatesForViewer all 404'd.
#
# Three stages (build-speed #1507):
#   1. carrier-base -- the expensive prefix (deps + tailwind + full source +
#      templ generate + build-css) that is IDENTICAL for all five carrier
#      node types (bff/cognition/agent/planner/workbench).
#   2. compile      -- the tag-specific `go build -tags <nt>`; FROM the base.
#   3. runtime      -- the distroless image carrying the binary + DSL trees.
# The five carriers differ ONLY by stage 2's build tag, so building the base
# ONCE and reusing it for five tag-only compiles is the #1507 dedup (see the
# CARRIER_BASE arg below).

# CARRIER_BASE must be a GLOBAL arg (declared before the first FROM) so it can
# be referenced by the `FROM ${CARRIER_BASE}` of the compile stage below. See
# the compile stage for what it selects.
ARG CARRIER_BASE=carrier-base

# ---------------------------------------------------------------------------
# Stage 1: carrier-base -- the expensive, tag-INDEPENDENT prefix.
# ---------------------------------------------------------------------------
FROM golang:1.26.4-alpine AS carrier-base

RUN apk add --no-cache git gcc musl-dev bash curl

WORKDIR /build

# Copy memql + __PRODUCT__-carrier in. Both are needed because the
# carrier statically links memql/app. Layer ordering: copy go.mod /
# go.sum + go.work first for caching, then the rest of the source.
#
# go.work is the critical knob: workspace mode means the build sees
# memql + __PRODUCT__-carrier as siblings + resolves cross-module
# imports through the local checkouts (not the module proxy). Without
# go.work, `go build` from __PRODUCT__-carrier/ would try to fetch
# memql at the version pinned in go.mod (a pre-#356 SHA that doesn't
# have the RegisterTree extension point or app.Run), and the build
# would fail with "undefined: memqldsl.RegisterTree".
#
# COPY paths are relative to the build context root (workspace
# parent). The context-root caller (docker compose) sets:
#     context: ../../          # from memql/docker/ -> workspace root
#     dockerfile: __PRODUCT__-carrier/Dockerfile
COPY go.work ./
COPY memql/go.mod memql/go.sum memql/
COPY __PRODUCT__-carrier/go.mod __PRODUCT__-carrier/go.sum __PRODUCT__-carrier/
# go.work references ./memql-cockpit too; create an empty stub so
# the workspace loads without that module's source.
RUN mkdir -p memql-cockpit && printf 'module github.com/znasllc-io/memql-cockpit\n\ngo 1.26.1\n' > memql-cockpit/go.mod

# Pre-fetch dependencies. Workspace-aware download pulls every
# transitive dep across all three modules in one pass.
#
# BuildKit cache mounts (build-speed #1506): the module cache
# (/go/pkg/mod) and the Go build cache (/root/.cache/go-build) persist
# across builds, so a rebuild of an unchanged tree reuses downloaded
# modules + already-compiled packages instead of redoing both. Every `go`
# step below mounts the SAME two caches -- modules fetched here must stay
# visible to templ generate + go build, and cache mounts are unmounted
# after each RUN (never baked into a layer), so an unmounted step would
# re-download. The `# syntax=docker/dockerfile:1` directive at the top of
# this file enables the mount syntax under both `docker buildx` and
# `az acr build` (both run BuildKit). The five carrier targets share these
# caches across parallel builds (default sharing=shared; Go's caches are
# concurrency-safe), so the cross-target Tailwind/network storms behind
# memql#1351 don't recur on the Go side either.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download -C memql
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download -C __PRODUCT__-carrier

# Pre-fetch the pinned standalone Tailwind binary into the exact path
# memql's scripts/identity/build-css.sh probes (bin/tools is dockerignored,
# so the source COPY below never clobbers it). Early layer = the ~100MB
# download only re-runs on a version bump, never on source changes --
# previously every refresh re-downloaded it concurrently across the five
# carrier targets and one TLS hiccup killed the whole cluster build
# (memql#1351). Keep TAILWIND_VERSION in sync with the script's pin; a
# missed bump degrades gracefully (the script re-downloads, with retries).
ARG TAILWIND_VERSION=v3.4.17
RUN set -e; \
    case "$(uname -m)" in \
        x86_64) platform=linux-x64 ;; \
        aarch64|arm64) platform=linux-arm64 ;; \
        *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
    esac; \
    mkdir -p memql/bin/tools; \
    curl -sSL --fail --retry 5 --retry-all-errors --retry-delay 2 \
        -o "memql/bin/tools/tailwindcss-${platform}" \
        "https://github.com/tailwindlabs/tailwindcss/releases/download/${TAILWIND_VERSION}/tailwindcss-${platform}"; \
    chmod +x "memql/bin/tools/tailwindcss-${platform}"

# Copy full source for both modules.
COPY memql/ memql/
COPY __PRODUCT__-carrier/ __PRODUCT__-carrier/

# Generate templ + tailwind from memql's tree -- needed because the
# carrier statically links memql/app's identity package which
# references the generated *_templ.go files. Skipping these turns
# the build into a 200-line "undefined" parade. Cheap enough to
# always run (a few seconds).
WORKDIR /build/memql
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go run github.com/a-h/templ/cmd/templ generate -path component/identity/web/templ
RUN bash scripts/identity/build-css.sh

# ---------------------------------------------------------------------------
# Stage 2: compile -- the tag-specific build, FROM the base.
# ---------------------------------------------------------------------------
# CARRIER_BASE selects the base image the tag-specific compile builds on:
#   - default `carrier-base` -> the in-Dockerfile stage above, so a
#     standalone `docker build` / single `az acr build` / docker-compose
#     build stays self-contained + correct (one build does prefix + compile,
#     exactly as before #1507).
#   - an EXTERNAL prebuilt+pushed base image (e.g.
#     acrmemql.azurecr.io/memql-carrier-base:<ver>) -> the five tagged
#     compiles skip the whole prefix and reuse the one base. This is how the
#     release build (memql scripts/deploy/aks-deploy.sh) and CI (#1509) dedup
#     the carriers: build the base ONCE, then five fast `go build -tags <nt>`.
# Either way the #1053 carrier-build rule holds -- the __PRODUCT__ DSL subtree
# is present in the base and statically linked at compile time.
# (CARRIER_BASE is declared as a global ARG at the top of this file -- a FROM
# can only reference args declared before the first FROM.)
FROM ${CARRIER_BASE} AS compile

# Build the carrier binary itself with the requested BUILD_TAGS.
# `bff` (default) produces the original BFF carrier. `agent`,
# `cognition`, `planner`, `workbench` produce same-DSL-tree variants for
# those node types -- the agent variant is the one #370 wires up so
# the agent binary can render the __PRODUCT__-side `agentReply`
# prompt.
ARG BUILD_TAGS=bff
WORKDIR /build/__PRODUCT__-carrier
# CGO_ENABLED=0 already yields a fully static binary, so the legacy
# `-a -installsuffix cgo` idiom is unnecessary -- and `-a` actively forces
# a rebuild of EVERY package (including the standard library) on every
# build, which would defeat the go-build cache mount added for #1506. Drop
# both: the produced binary is byte-for-byte equivalent (same static link,
# same flags) while the build cache now makes an unchanged-tree rebuild an
# incremental compile instead of a from-scratch one.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux go build -tags "${BUILD_TAGS}" -ldflags="-s -w" -o memql .

# Reuse memql's healthcheck binary -- same shape, same /healthz
# probe contract. Lives in the memql repo's cmd/ tree.
WORKDIR /build/memql
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /build/__PRODUCT__-carrier/healthcheck ./cmd/healthcheck

# ---------------------------------------------------------------------------
# Stage 3: runtime.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/base-debian12

WORKDIR /app

COPY --from=compile /build/__PRODUCT__-carrier/memql .
COPY --from=compile /build/__PRODUCT__-carrier/healthcheck .

# DSL trees: memql's embedded baseline lives inside the binary via
# go:embed (memql/dsl/embed.go) AND the __PRODUCT__ overlay lives
# inside the binary via go:embed (__PRODUCT__-carrier/dsl/__PRODUCT__/
# embed.go). The on-disk copies below are only kept so a runtime
# MEMQL_DSL_PATH override works from inside the container; the
# default boot doesn't read them.
COPY --from=compile /build/memql/dsl ./dsl
COPY --from=compile /build/__PRODUCT__-carrier/dsl ./dsl-__PRODUCT__
COPY --from=compile /build/memql/VERSION ./VERSION

EXPOSE 8085 50051

ENTRYPOINT ["/app/memql"]
