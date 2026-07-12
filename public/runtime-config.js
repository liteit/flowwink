// Runtime Supabase config override. Empty by default: the values baked in at
// build time apply (Vercel, vite dev). In Docker deployments the container
// entrypoint (docker/40-runtime-env.sh) regenerates this file from container
// env vars on every start, so one image can point at any Supabase instance.
// Loaded as a blocking classic script in index.html BEFORE the app bundle.
globalThis.__FLOWWINK_ENV__ = {};
