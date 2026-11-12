#!/usr/bin/env bash
# Bootstraps a fresh VPS as a stateless relay: WireGuard (wg1) + DNAT 80/443/853 -> homelab.
# Run FROM THE HOMELAB:   ./bootstrap-vps.sh <ssh-host> [--update-homelab]
#   <ssh-host>         e.g. "vps" (entry from ~/.ssh/config) or root@1.2.3.4
#   --update-homelab   after install, sets the new IP as the homelab Endpoint and recreates wireguard+caddy
# Requires: Debian/Ubuntu on the VPS, root/sudo over SSH, proxy/wg-edge/vps/wg1.cutover.conf.
set -euo pipefail

HOST="${1:?usage: $0 <ssh-host> [--update-homelab]}"
UPDATE_HOMELAB="${2:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
WG_EDGE="$DIR/../proxy/wg-edge"
CONF="$WG_EDGE/vps/wg1.cutover.conf"
HOMELAB_CONF="$WG_EDGE/config/wg_confs/wg0.conf"
COMPOSE_DIR="$DIR/../proxy"
[ -f "$CONF" ] || { echo "Missing $CONF"; exit 1; }

SSH=(ssh -o ConnectTimeout=15 "$HOST")

echo ">> 1/5 Packages (wireguard, iptables)"
"${SSH[@]}" 'export DEBIAN_FRONTEND=noninteractive; sudo apt-get update -qq && sudo apt-get install -y -qq wireguard iptables'

echo ">> 2/5 IP forwarding (persistent)"
"${SSH[@]}" 'echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wg-relay.conf >/dev/null && sudo sysctl -q --system'

echo ">> 3/5 Detecting public interface and configuring wg1"
IFACE="$("${SSH[@]}" "ip -4 route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1")"
[ -n "$IFACE" ] || { echo "Could not detect the public interface"; exit 1; }
echo "   interface: $IFACE"
sed "s/-i eth0/-i $IFACE/g; s/-o eth0/-o $IFACE/g" "$CONF" | "${SSH[@]}" 'sudo install -m600 /dev/stdin /etc/wireguard/wg1.conf'

echo ">> 4/5 Start (and enable on boot) wg-quick@wg1"
"${SSH[@]}" 'sudo systemctl enable wg-quick@wg1 && sudo systemctl restart wg-quick@wg1'
"${SSH[@]}" 'command -v ufw >/dev/null && sudo ufw status | grep -q active && { sudo ufw allow 51821/udp; sudo ufw allow 80,443,853/tcp; sudo ufw allow 443/udp; sudo ufw route allow in on '"$IFACE"' out on wg1; } || true'

echo ">> 5/5 Verification"
"${SSH[@]}" 'sudo wg show wg1 | grep -E "interface|listening|peer"; sudo iptables -t nat -S PREROUTING | grep DNAT'
IP="$("${SSH[@]}" "ip -4 -o addr show dev $IFACE | awk '{print \$4}' | cut -d/ -f1 | head -1")"
echo "   New VPS public IP: $IP"

if [ "$UPDATE_HOMELAB" = "--update-homelab" ]; then
  echo ">> Homelab: Endpoint -> $IP:51821"
  sed -i "s#^Endpoint = .*#Endpoint = $IP:51821#" "$HOMELAB_CONF"
  # caddy shares wireguard's network namespace, so it must be recreated together with wireguard
  (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate wireguard caddy)
  sleep 25
  docker exec wireguard wg show | grep -E "endpoint|handshake" || echo "WARNING: no handshake"
fi

cat <<EOF

Done. Remaining manual steps:
  1. Point the DNS A records (piekna2.pl, eliteservice.pl and subdomains) to: $IP
  2. After DNS propagates, check:  curl -I https://photos.piekna2.pl  oraz  openssl s_client -connect dns.piekna2.pl:853 -alpn dot
  3. You can destroy the old VPS (certificates live on the homelab: proxy/caddy/data).
EOF
