# =============================================================================
# FlowWink frontend — self-hosted deployment (Easypanel, Docker, any VPS)
# =============================================================================
# Multi-stage: Node builds the Vite SPA, nginx serves the static output using
# the nginx.conf checked into the repo root (SPA routing, caching, /health).
#
# IMPORTANT: VITE_* variables are baked into the bundle AT BUILD TIME. They
# must be provided as build args (Easypanel passes service env vars as build
# args automatically for Dockerfile builds):
#
#   docker build \
#     --build-arg VITE_SUPABASE_URL=https://<ref>.supabase.co \
#     --build-arg VITE_SUPABASE_PUBLISHABLE_KEY=<anon-key> \
#     --build-arg VITE_SUPABASE_PROJECT_ID=<ref> \
#     -t flowwink .
#
# Changing them later requires a rebuild, not a restart.
# =============================================================================

FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_PUBLISHABLE_KEY
ARG VITE_SUPABASE_PROJECT_ID
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_PUBLISHABLE_KEY=$VITE_SUPABASE_PUBLISHABLE_KEY \
    VITE_SUPABASE_PROJECT_ID=$VITE_SUPABASE_PROJECT_ID \
    # Large SPA — give Vite headroom on small VPS builders
    NODE_OPTIONS=--max-old-space-size=4096

# prebuild (run-migrations.js) self-skips without the Supabase CLI; DB
# migrations are applied separately (supabase db push), never from the image.
RUN npm run build

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/health || exit 1
