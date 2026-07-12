#!/bin/sh
# Regenerates /runtime-config.js from container env vars on every start.
# Runs automatically via the nginx image's /docker-entrypoint.d/ hook.
# Only vars that are actually set are emitted — unset vars fall back to the
# values baked into the bundle at build time (see vite.config.ts).
set -e

OUT=/usr/share/nginx/html/runtime-config.js

{
  echo "// Generated at container start from environment variables."
  echo "globalThis.__FLOWWINK_ENV__ = {"
  for key in VITE_SUPABASE_URL VITE_SUPABASE_PUBLISHABLE_KEY VITE_SUPABASE_PROJECT_ID; do
    eval "val=\${$key:-}"
    if [ -n "$val" ]; then
      # Values are URLs/JWTs/refs — no quotes or backslashes to escape, but
      # reject embedded quotes defensively rather than emit broken JS.
      case "$val" in
        *\"*|*\\*) echo "40-runtime-env: refusing $key with quote/backslash" >&2; exit 1 ;;
      esac
      printf '  %s: "%s",\n' "$key" "$val"
    fi
  done
  echo "};"
} > "$OUT"

echo "40-runtime-env: wrote $OUT ($(grep -c 'VITE_' "$OUT" || true) override(s))"
