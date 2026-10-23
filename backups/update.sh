#!/usr/bin/env bash
# Update backups: rebuild the image, restart the container, remove old images.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Rebuilding image and restarting"
docker compose up -d --build

echo "==> Removing old (dangling) images"
docker image prune -f
