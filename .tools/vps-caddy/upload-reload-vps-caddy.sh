#!/bin/bash

# Script to upload Caddyfile to VPS and reload Caddy
# Usage: ./upload-reload-vps-caddy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CADDY_FILE="$SCRIPT_DIR/vps-caddy-file"
REMOTE_CADDY_FILE="/etc/caddy/Caddyfile"
VPS_HOST="vps"

echo "📤 Uploading Caddyfile to VPS..."
scp "$LOCAL_CADDY_FILE" "$VPS_HOST:/tmp/Caddyfile.new"

echo "🔒 Moving Caddyfile to $REMOTE_CADDY_FILE (requires sudo)..."
ssh "$VPS_HOST" "sudo mv /tmp/Caddyfile.new $REMOTE_CADDY_FILE"

echo "🔄 Reloading Caddy on VPS..."
ssh "$VPS_HOST" "sudo caddy reload --config $REMOTE_CADDY_FILE"

echo "✅ Done! Caddy configuration updated and reloaded on VPS."
