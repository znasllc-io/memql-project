# syntax=docker/dockerfile:1

ARG NODE_VERSION=22.12.0
FROM node:${NODE_VERSION}-alpine AS base

WORKDIR /app

# ---------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------
#
# Phase 6/8 of the env-var refactor (memql/docs/planning/env-var-refactor-plan.md):
# the only VITE_* values still baked into the bundle are the bootstrap
# envelope -- backend URLs and the identity-service OAuth client id.
# Model names, voice defaults, feature flags, and integration secrets all
# resolve at runtime from memQL's v1:platform:variable / :secret
# concepts via src/lib/publicConfig.ts and the gRPC API key resolver,
# respectively. Operators populate those concepts via:
#
#   make secrets-init            (interactive)
#   make secrets-seed
#   make variable-set NAME=... VALUE=... SCOPE=global
#
# in the memQL repo. No third-party API key, model name, or feature
# flag should be added back to this file without a corresponding
# update to that workflow.

FROM base AS builder

# ---- Bootstrap envelope (build-time, baked into the bundle) ----------

# Backend connection (browser must know where memQL lives at boot).
ARG VITE_MEMQL_WS_URL
ARG VITE_MEMQL_AUDIO_WS_URL
ARG VITE_MEMQL_TOKEN_EXCHANGE_URL
# (VITE_MEMQL_API_URL is derived from VITE_MEMQL_WS_URL at runtime,
#  so it doesn't need to be a separate build arg.)

# In-house identity service -- what the app actually reads (src/main.tsx +
# src/lib/auth/oauth.ts). VITE_IDENTITY_CLIENT_ID defaults to 'app' when unset.
ARG VITE_IDENTITY_BASE_URL
ARG VITE_IDENTITY_CLIENT_ID

# Dev-only auth bypass.
ARG VITE_BYPASS_AUTH

# Public LiveAvatar sandbox flag (just a bool; the API key + avatar
# id + voice id all live in memQL post-Phase-5).
ARG VITE_LIVEAVATAR_SANDBOX

# Forward ARGs to ENV so process.env contains them for npm run build.
ENV VITE_MEMQL_WS_URL=${VITE_MEMQL_WS_URL}
ENV VITE_MEMQL_AUDIO_WS_URL=${VITE_MEMQL_AUDIO_WS_URL}
ENV VITE_MEMQL_TOKEN_EXCHANGE_URL=${VITE_MEMQL_TOKEN_EXCHANGE_URL}
ENV VITE_IDENTITY_BASE_URL=${VITE_IDENTITY_BASE_URL}
ENV VITE_IDENTITY_CLIENT_ID=${VITE_IDENTITY_CLIENT_ID}
ENV VITE_BYPASS_AUTH=${VITE_BYPASS_AUTH}
ENV VITE_LIVEAVATAR_SANDBOX=${VITE_LIVEAVATAR_SANDBOX}

# GitHub Packages auth for the private @__PRODUCT_ORG__ / @znasllc-io SDKs.
# .npmrc reads ${NODE_AUTH_TOKEN} at install time. Mounted as a BuildKit
# secret (NOT an ARG) so the token never lands in build logs, the image
# layers, or the image history. Build with:
#   docker buildx build --secret id=node_auth_token,env=NODE_AUTH_TOKEN ...
#
# NOTE: the starter shell is self-contained (no private scoped deps yet),
# so `npm install` here resolves entirely from the public registry; the
# secret + .npmrc wiring is kept so the product can drop in its published
# SDK without touching the image. package-lock.json is intentionally not
# COPYed (the starter ships none) -- `npm install` generates it in-layer.
COPY package.json .npmrc ./
# BuildKit npm cache mount (build-speed): the npm store (/root/.npm)
# persists across builds, so an unchanged dependency tree re-installs from
# the local cache instead of re-fetching every tarball from the registry.
# Sits alongside the existing secret mount (multiple mounts per RUN are
# fine); requires BuildKit, which both `docker buildx` and `az acr build`
# run (the `# syntax=docker/dockerfile:1` directive is already at the top).
RUN --mount=type=secret,id=node_auth_token,required=true \
    --mount=type=cache,target=/root/.npm \
    NODE_AUTH_TOKEN="$(cat /run/secrets/node_auth_token)" npm install --legacy-peer-deps
COPY . .
RUN npm run build

# ---------------------------------------------------------------------
# Runner stage
# ---------------------------------------------------------------------
#
# Static tier. The lean starter ships NO server (no Express/SSR); it just
# serves the built Vite bundle from dist/ over HTTP. A product that needs
# a backend server (SSR, /api endpoints, a token-exchange proxy) wires its
# own runner stage + entrypoint here.

FROM base AS runner
ENV NODE_ENV=production

# Lightweight static file server (public package, no auth needed).
RUN npm install -g serve@14

# Copy the built frontend.
COPY --from=builder /app/dist ./dist

EXPOSE 8080

CMD ["serve", "-s", "dist", "-l", "8080"]
