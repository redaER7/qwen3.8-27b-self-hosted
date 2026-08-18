#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# GPU node WireGuard + K3s agent join
# ------------------------------------------------------------

WG_IFACE="wg0"
WG_NET="10.10.0.2/24"
WG_PORT=""                                        # prompted below (default 29817)
CP_ENDPOINT="<CONTROL_PLANE_PUBLIC_IP>:51820"     # will prompt
CP_PUBLIC_KEY="<CONTROL_PLANE_PUBLIC_KEY>"        # will prompt
K3S_CONFIG="/etc/rancher/k3s/config.yaml"

: "${K3S_NODE_NAME:=gpu-node-$(hostname)}"

# 1. Install WireGuard
echo "📦 Installing WireGuard..."
apt update && apt install -y wireguard

# 2. Generate keys (if not present)
cd /etc/wireguard
if [[ ! -f privatekey ]]; then
    umask 077
    wg genkey | tee privatekey | wg pubkey > publickey
    echo "✅ Keys generated."
else
    echo "ℹ️  Keys already exist, using them."
fi
PRIV=$(cat privatekey)
PUB=$(cat publickey)

echo "🔑 Your public key (give this to the control‑plane node):"
echo "   $PUB"
echo ""

# 3. Gather control‑plane details
read -p "Enter the control‑plane public key: " CP_PUBLIC_KEY
read -p "Enter the control‑plane public IP address (e.g. <CP_PUBLIC_IP>): " CP_IP
read -p "Enter the control‑plane WireGuard port [51820]: " CP_PORT
CP_PORT="${CP_PORT:-51820}"
CP_ENDPOINT="${CP_IP}:${CP_PORT}"

# 4. Choose the local WireGuard listen port
# Trooper AI's external firewall only allows inbound UDP 29817-29836, so pick a
# port in that range or the control plane's replies will be dropped.
read -p "Enter this GPU node's WireGuard listen port [29817]: " WG_PORT
WG_PORT="${WG_PORT:-29817}"
if [[ "$WG_PORT" -lt 29817 || "$WG_PORT" -gt 29836 ]]; then
    echo "⚠️  Warning: $WG_PORT is outside the Trooper AI allowed inbound UDP range (29817-29836)."
    echo "   The control plane may not be able to reach this node unless you open $WG_PORT/udp inbound."
fi

# 5. Create wg0.conf (GPU as client)
cat > wg0.conf <<EOF
[Interface]
Address = $WG_NET
ListenPort = $WG_PORT
PrivateKey = $PRIV

[Peer]
PublicKey = $CP_PUBLIC_KEY
Endpoint = $CP_ENDPOINT
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

echo "✅ WireGuard config created."
echo "ℹ️  This node listens on UDP ${WG_PORT}."
echo "   Ensure inbound UDP ${WG_PORT} is allowed in the Trooper AI firewall, and tell the"
echo "   control plane to add this peer with:"
echo "       Endpoint = <GPU_PUBLIC_IP>:${WG_PORT}"
echo ""

# 6. Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
echo "✅ WireGuard started."

# 7. Test connectivity
echo "⏳ Testing ping to control‑plane (10.10.0.1)..."
if ping -c 2 10.10.0.1 >/dev/null; then
    echo "✅ WireGuard tunnel is UP."
else
    echo "❌ Cannot reach 10.10.0.1. Please check firewall and config."
    exit 1
fi

# test
timeout 5 curl -v -k https://10.10.0.1:6443