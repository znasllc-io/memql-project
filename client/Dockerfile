# syntax=docker/dockerfile:1

ARG NODE_VERSION=22.12.0
FROM node:${NODE_VERSION}-alpine AS base

WORKDIR /app

# ---------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------
#
# Bootstrap envelope (build-time, baked into the bundle): the ONLY VITE_*
# values src/ actually reads are the two backend URLs --
#   VITE_MEMQL_HTTP_URL   (src/context/Session.tsx: the bff front door the
#                          browser talks to; the /memql WS bridge + query surface)
#   VITE_IDENTITY_BASE_URL (src/lib/auth/identity.ts: the magic-link + JWKS host)
# Everything else (model names, voice defaults, feature flags, integration
# secrets) resolves at runtime from memQL's v1:platform:variable / :secret
# concepts -- do not add build args for them here.

FROM base AS builder

ARG VITE_MEMQL_HTTP_URL
ARG VITE_IDENTITY_BASE_URL

# Forward ARGs to ENV so process.env contains them for `npm run build`.
ENV VITE_MEMQL_HTTP_URL=${VITE_MEMQL_HTTP_URL}
ENV VITE_IDENTITY_BASE_URL=${VITE_IDENTITY_BASE_URL}

# GitHub Packages auth for the private @__PRODUCT_ORG__ / @znasllc-io SDKs.
# .npmrc reads ${NODE_AUTH_TOKEN} at install time, mounted as a BuildKit secret
# (NOT an ARG) so the token never lands in build logs, layers, or history.
#
# The secret is OPTIONAL (required=false): the starter shell is self-contained
# (no private scoped deps yet), so `npm install` resolves entirely from the
# public registry and `docker build` works with no secret. When missing, the
# mount file is empty and NODE_AUTH_TOKEN is unset -- fine for public deps. A
# product that drops in its published SDK just passes the secret:
#   docker buildx build --secret id=node_auth_token,env=NODE_AUTH_TOKEN ...
# package-lock.json is intentionally not COPYed (the starter ships none) --
# `npm install` generates it in-layer.
COPY package.json .npmrc ./
# BuildKit npm cache mount (build-speed): the npm store persists across builds.
RUN --mount=type=secret,id=node_auth_token,required=false \
    --mount=type=cache,target=/root/.npm \
    NODE_AUTH_TOKEN="$(cat /run/secrets/node_auth_token 2>/dev/null || true)" \
    npm install --legacy-peer-deps
COPY . .
RUN npm run build

# ---------------------------------------------------------------------
# Runner stage
# ---------------------------------------------------------------------
#
# Static tier. The lean starter ships NO server (no Express/SSR); it just serves
# the built Vite bundle from dist/ over HTTP. A product that needs a backend
# server (SSR, /api endpoints, a token-exchange proxy) wires its own runner
# stage + entrypoint here.

FROM base AS runner
ENV NODE_ENV=production

# Lightweight static file server (public package, no auth needed).
RUN npm install -g serve@14

COPY --from=builder /app/dist ./dist

EXPOSE 8080

CMD ["serve", "-s", "dist", "-l", "8080"]
