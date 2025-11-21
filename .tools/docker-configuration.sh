#!/usr/bin/env bash

# Idempotent Docker network creation script.
# Creates two bridge networks used across the stack:
#   reverse-proxy   -> shared between caddy and services it fronts
#   monitoring      -> optional dedicated network for Prometheus/Grafana (can be same as reverse-proxy if desired)
# Safe to run multiple times; existing networks are left untouched.

set -euo pipefail

REVERSE_PROXY_NET="reverse-proxy"
MONITORING_NET="monitoring"
DRIVER="bridge"

create_network() {
	local net_name="$1"
	if docker network inspect "$net_name" >/dev/null 2>&1; then
		echo "[SKIP] Network '$net_name' already exists"
	else
		echo "[CREATE] Network '$net_name' (driver=$DRIVER)"
		docker network create --driver "$DRIVER" "$net_name"
	fi
}

echo "== Docker network setup =="
create_network "$REVERSE_PROXY_NET"
create_network "$MONITORING_NET"
echo "== Done =="

