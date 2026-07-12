# Self-hosted frontend (Docker / Easypanel / any VPS)

The frontend normally deploys to Vercel (auto-deploy on push, `vercel.json`).
For enterprise/self-hosted scenarios — an internal server behind the company
firewall — the repo ships a `Dockerfile` that builds the Vite SPA and serves
it with nginx using the checked-in `nginx.conf` (SPA routing, asset caching,
`/health` endpoint).

## The one thing that bites everyone

**`VITE_*` variables are baked into the JS bundle at BUILD time.** Setting
them as runtime container env does nothing — the bundle is already compiled.
They must reach `docker build` as build args, and changing them requires a
**rebuild**, not a restart.

Required:

| Build arg | Value |
|---|---|
| `VITE_SUPABASE_URL` | `https://<ref>.supabase.co` |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | the anon/publishable key |
| `VITE_SUPABASE_PROJECT_ID` | `<ref>` |

## Prebuilt image (recommended for small VPSes)

The Vite build needs ~4 GB RAM — on a small VPS the builder gets OOM-killed
mid-`transforming...` with **no error in the Easypanel log** (it just stops).
Two fixes:

- **Pull instead of build (recommended):** the
  `docker-image.yml` GitHub Action builds on every push to main and publishes
  `ghcr.io/<owner>/flowwink-frontend:dev` (+ `:dev-<sha>`). In Easypanel,
  create the App with source **Docker Image** instead of GitHub. If the ghcr
  package is private, either make it public (it contains only public code +
  the anon key) or add registry credentials in Easypanel (GitHub username +
  a PAT with `read:packages`). Instance targeting: the image bakes the dev
  instance by default; override via the `VITE_*` repository *variables* or a
  matrix entry in the workflow.
- **Build on the VPS anyway:** add swap first —
  `fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
  (persist with an `/etc/fstab` entry), then rebuild.

Build-log canary: with the `VITE_*` build args present, the prebuild step
prints `📦 Checking for pending database migrations...` /
`ℹ️ Supabase CLI not available` — if you instead see
`⚠️ Supabase not configured`, the env vars did not reach the build.

## Easypanel (building from source)

1. Create an **App** service from the GitHub repo, **Build: Dockerfile**
   (the repo-root `Dockerfile`; no custom build/start commands).
2. Add the three `VITE_*` variables under **Environment** — Easypanel passes
   service env vars as `--build-arg` to Dockerfile builds, which is exactly
   what the `ARG` declarations expect.
3. Container port: **80**. Attach your domain; Easypanel's proxy handles TLS.
4. Health check path: `/health`.
5. Redeploy after changing any `VITE_*` value (rebuild, see above).

## Plain Docker

```bash
docker build \
  --build-arg VITE_SUPABASE_URL=https://<ref>.supabase.co \
  --build-arg VITE_SUPABASE_PUBLISHABLE_KEY=<anon-key> \
  --build-arg VITE_SUPABASE_PROJECT_ID=<ref> \
  -t flowwink-frontend .

docker run -d -p 8080:80 flowwink-frontend
curl http://localhost:8080/health   # → healthy
```

## What differs from Vercel

`vercel.json` wires three serverless functions (`api/og.ts`, `api/robots.ts`,
`api/sitemap.ts`) plus a social-crawler rewrite. In the Docker deployment
nginx covers these instead:

- `/robots.txt`, `/sitemap.xml` — nginx returns sane static fallbacks.
- **Social-crawler SSR (OG tags)** — opt-in: uncomment the `proxy_pass`
  blocks in `nginx.conf` and set your Supabase URL to route crawlers to the
  `render-page` / `sitemap-xml` edge functions. Until then, crawlers get the
  SPA's default meta tags. Fine for an internal server; configure it for a
  public-facing self-hosted site.

## Scope reminder — this is 1 of 4 layers

A FlowWink site is schema + skills + edge functions + frontend
(see [provisioning-and-updates.md](./provisioning-and-updates.md)). This
Dockerfile only moves the **frontend** off Vercel. The backend is still a
Supabase project: run migrations (`supabase db push`), deploy edge functions,
and sync skills exactly as for any other instance. Fully air-gapped operation
(self-hosted Supabase on the same VPS) is a separate track — the frontend
container doesn't care where the Supabase URL points, so it already works
against a self-hosted Supabase if you stand one up.

Build notes: the `prebuild` migration script self-skips inside the image (no
Supabase CLI present) — migrations never run from the image build. The build
stage sets `NODE_OPTIONS=--max-old-space-size=4096`; the Vite build is large,
so give the builder VPS ~4 GB (or build the image elsewhere and push to a
registry Easypanel pulls from).
