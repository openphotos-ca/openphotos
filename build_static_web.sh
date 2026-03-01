#!/usr/bin/env bash
set -euo pipefail
# Always clean build artifacts to avoid stale EE/OSS aliasing
rm -rf web-photos/out web-photos/.next web-photos/tsconfig.tsbuildinfo || true
# Build the static web UI under web-photos/out

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_DIR="$ROOT_DIR/web-photos"
## Do not force EE in OSS builds; honor env if provided
## To enable EE UI explicitly, run: NEXT_PUBLIC_ENABLE_EE=1 ./build_static_web.sh
cd "$WEB_DIR"

# Ensure API URL is set (default to same-origin API)
API_URL_DEFAULT="/api"
API_URL="${NEXT_PUBLIC_API_URL:-$API_URL_DEFAULT}"

# Only create .env.local if missing; prefer same-origin by default
if [ ! -f .env.local ]; then
  echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.local
  echo "Created .env.local with NEXT_PUBLIC_API_URL=$API_URL"
else
  echo "Using existing .env.local"
fi

if command -v npm >/dev/null 2>&1; then
  if [ -f package-lock.json ]; then
    # Prefer reproducible install; fall back to npm install when lockfile is out of date
    if ! npm ci; then
      echo "npm ci failed; falling back to npm install (updating lockfile)" >&2
      npm install
    fi
  else
    npm install
  fi
else
  echo "npm not found in PATH" >&2
  exit 1
fi

# Build static export (Next.js 14+ uses output: export)
# Force same-origin /api by default for production-safe bundles, even when
# .env.local has a localhost URL. Caller can still override explicitly.
NEXT_PUBLIC_API_URL="$API_URL" \
NEXT_PUBLIC_ENABLE_EE="${NEXT_PUBLIC_ENABLE_EE:-}" \
npm run build

echo "\n✅ Static site exported to: $WEB_DIR/out"
echo "To test locally: npx serve \"$WEB_DIR/out\""
# Inform about EE flag
if [ "${NEXT_PUBLIC_ENABLE_EE:-}" = "1" ] || [ "${NEXT_PUBLIC_ENABLE_EE:-}" = "true" ]; then
  echo "Building with Enterprise UI enabled (NEXT_PUBLIC_ENABLE_EE=${NEXT_PUBLIC_ENABLE_EE})"
else
  echo "Building without Enterprise UI (NEXT_PUBLIC_ENABLE_EE not set)"
fi
