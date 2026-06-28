#!/bin/bash

set -e

CONTAINER_NAME="homeassistant"
CONFIG_PATH_IN_CONTAINER="/config"
HACS_PATH_IN_CONTAINER="$CONFIG_PATH_IN_CONTAINER/custom_components/hacs"

echo "=== HACS installer (host → Docker container) ==="

# 1. Check if the container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "❌ Container '${CONTAINER_NAME}' is not running"
  exit 1
fi

# 2. Check if HACS is already installed
if docker exec "$CONTAINER_NAME" test -d "$HACS_PATH_IN_CONTAINER"; then
  echo "⚠️  HACS is already installed"
  exit 0
fi

# 3. Run the installer inside the container
echo "⬇️  Installing HACS..."
docker exec "$CONTAINER_NAME" bash -c \
  "mkdir -p /config/custom_components && wget -qO- https://get.hacs.xyz | bash -"

# 4. Verify installation
if docker exec "$CONTAINER_NAME" test -d "$HACS_PATH_IN_CONTAINER"; then
  echo "✅ HACS installed successfully"
  echo "➡️  Restart the container:"
  echo "   docker restart ${CONTAINER_NAME}"
else
  echo "❌ HACS installation failed"
  exit 1
fi
