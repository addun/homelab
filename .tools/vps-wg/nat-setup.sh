#!/bin/bash

# Remember to install iptables-persistent first on VPS
# $ sudo apt update && sudo apt install iptables-persistent -y

REMOTE_HOST="vps"

echo "🚀 Connecting to $REMOTE_HOST to configure WireGuard..."

ssh $REMOTE_HOST << 'EOF'
    # 1. Detect the public network interface
    V_NET=$(ip route | grep default | awk '{print $5}')

    if [ -z "$V_NET" ]; then
        echo "❌ Error: Could not detect public network interface."
        exit 1
    fi

    echo "🌐 Public Interface detected: $V_NET"

    # 2. Enable IP Forwarding in the kernel (if not already done)
    sudo sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null

    # 3. Apply the NAT (Masquerade) and Forwarding rules
    echo "🛡️ Applying iptables rules..."
    sudo iptables -t nat -A POSTROUTING -o "$V_NET" -j MASQUERADE
    sudo iptables -A FORWARD -i wg0 -j ACCEPT
    sudo iptables -A FORWARD -o wg0 -j ACCEPT

    # 4. Make rules persistent (Install iptables-persistent if missing)
    echo "💾 Saving rules for reboot..."
    if ! command -v iptables-save &> /dev/null; then
        sudo apt update && sudo apt install iptables-persistent -y
    else
        # Save the current rules to the persistent file
        sudo sh -c "iptables-save > /etc/iptables/rules.v4"
    fi

    echo "✅ NAT routing is now active."
    echo "👉 Now change 'AllowedIPs = 0.0.0.0/0' in your Home Docker wg0.conf and restart it."
EOF

