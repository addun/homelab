#!/bin/bash

# Configuration
REMOTE_HOST="vps"
WG_CONF="/etc/wireguard/wg0.conf"

echo "🚀 Connecting to $REMOTE_HOST to configure WireGuard..."

ssh $REMOTE_HOST << 'EOF'
    # 1. Ensure WireGuard is installed
    if ! command -v wg &> /dev/null; then
        sudo apt update && sudo apt install wireguard -y
    fi

    # 2. Fix permissions (WireGuard keys must be private)
    sudo chown root:root /etc/wireguard/
    sudo chmod 700 /etc/wireguard/
    
    # 3. Enable IP Forwarding (so traffic can move through the VPS)
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null

    # 4. Open the Firewall (UDP port 51820)
    if command -v ufw &> /dev/null; then
        sudo ufw allow 51820/udp
    fi

    # 5. Restart the interface to apply changes
    # We use 'down' first in case it's already running, then 'up'
    sudo wg-quick down wg0 2>/dev/null
    sudo wg-quick up wg0

    # 6. Set it to start automatically on reboot
    sudo systemctl enable wg-quick@wg0

    echo "✅ VPS WireGuard is UP"
    sudo wg show
EOF