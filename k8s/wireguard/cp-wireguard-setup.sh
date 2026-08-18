#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Control‑plane WireGuard + K3s configuration
# ------------------------------------------------------------

WG_IFACE="wg0"
WG_PORT="51820"
WG_NET="10.10.0.1/24"
WG_PEER_IP="10.10.0.2/32"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"

# 1. Install WireGuard
echo "📦 Installing WireGuard..."
apt update && apt install -y wireguard

# 2. Generate keys (if not already present)
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

# 3. Create wg0.conf (control‑plane as listener)
cat > wg0.conf <<EOF
[Interface]
Address = $WG_NET
ListenPort = $WG_PORT
PrivateKey = $PRIV
SaveConfig = false

[Peer]
# Replace this PublicKey with the GPU node's public key
PublicKey = <GPU_NODE_PUBLIC_KEY>
AllowedIPs = $WG_PEER_IP
EOF

echo "✅ WireGuard config created at /etc/wireguard/wg0.conf"
echo "🔑 Your public key (needed on GPU node):"
echo "   $PUB"
echo ""
echo "👉 Please edit /etc/wireguard/wg0.conf and replace <GPU_NODE_PUBLIC_KEY>"
echo "   with the public key from the GPU node, then run:"
echo "   sudo systemctl enable wg-quick@wg0 && sudo systemctl start wg-quick@wg0"
echo ""
read -p "Press Enter after you have updated the config and started WireGuard..."

# 4. Enable and start WireGuard (if not running)
if ! systemctl is-active --quiet wg-quick@wg0; then
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
fi
echo "✅ WireGuard running."

# 5. Configure K3s master to use the WireGuard IP
mkdir -p $(dirname $K3S_CONFIG)
cat > $K3S_CONFIG <<EOF
node-ip: 10.10.0.1
advertise-address: 10.10.0.1
node-external-ip: $(curl -s ifconfig.me)
EOF

echo "✅ K3s config written to $K3S_CONFIG"

# 6. Restart K3s
echo "🔄 Restarting K3s server..."
systemctl restart k3s
sleep 5
systemctl status k3s --no-pager | head -10

# Ensure CP node uses public IPv4 address
PUBLIC_IP="${CP_PUBLIC_IP:-<CP_PUBLIC_IP>}"
echo "Public IP: $PUBLIC_IP"

# Update config with correct external IP
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
node-ip: 10.10.0.1
advertise-address: 10.10.0.1
node-external-ip: $PUBLIC_IP
bind-address: 0.0.0.0
EOF

# Verify the config
sudo cat /etc/rancher/k3s/config.yaml

# Restart K3s
sudo systemctl restart k3s
sleep 10

sudo ufw allow from 10.10.0.0/24 to any port 6443 proto tcp
sudo ufw reload

#ping -c 4 10.10.0.2