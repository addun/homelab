#!/usr/bin/env bash
# Update cowkoszyku: pull the app repo, rebuild images, restart the stack, prune old images.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Pulling repo"
before="$(git -C repo rev-parse HEAD)"
git -C repo pull --ff-only
after="$(git -C repo rev-parse HEAD)"

if [ "$before" = "$after" ] && [ "${1:-}" != "--force" ]; then
  echo "Already up to date ($(git -C repo rev-parse --short HEAD)). Use --force to rebuild anyway."
  exit 0
fi

echo "==> Rebuilding and restarting ($(git -C repo rev-parse --short "$before") -> $(git -C repo rev-parse --short "$after"))"
docker compose up -d --build --remove-orphans

echo "==> Status"
docker compose ps

echo "==> Removing old (dangling) images"
docker image prune -f
