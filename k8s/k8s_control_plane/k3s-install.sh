#!/usr/bin/env bash
set -euo pipefail

# K3s Control Plane Installer

INSTALL_K3S_VERSION="v1.33.2+k3s1"

echo "[1/5] Installing K3s v1.33"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
  sh -s - \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644 \
    --flannel-iface=wg0

echo "[2/5] Writing K3s config"
read -rp "Enter the CP node's public IP (e.g. <CP_PUBLIC_IP>): " PUBLIC_IP
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
node-ip: 10.10.0.1
advertise-address: 10.10.0.1
node-external-ip: $PUBLIC_IP
flannel-iface: wg0
EOF
sudo systemctl restart k3s

echo "[3/5] Waiting for node to be ready"
for i in $(seq 1 30); do
  if k3s kubectl get node "$(hostname)" 2>/dev/null | grep -q Ready; then
    echo "   Node ready"
    break
  fi
  sleep 3
done

echo "[4/5] Labeling control plane node"
k3s kubectl label node "$(hostname)" \
  node-role.kubernetes.io/control-plane="true" \
  --overwrite 2>/dev/null || true

echo "[5/5] K3s control plane ready"
NODE_IP=$(k3s kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)

# Create kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config

echo ""
echo "=========================================="
echo " K3s Control Plane Ready"
echo "=========================================="
echo " K3S_URL=https://${NODE_IP}:6443"
echo " K3S_TOKEN=${TOKEN}"
echo "=========================================="
echo ""
echo "Copy the values above and use them in the GPU bootstrap script."
echo ""
echo "Next steps on each GPU node:"
echo "  1. Set up WireGuard (bash wireguard/gpu-wireguard-setup.sh)"
echo "  2. Install K3s agent with:"
echo "     curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.33.2+k3s1 \\"
echo "       K3S_URL=https://${NODE_IP}:6443 K3S_TOKEN=\${TOKEN} \\"
echo "       K3S_NODE_NAME=gpu-node-\\$(hostname) \\"
echo "       INSTALL_K3S_EXEC='agent --node-ip=10.10.0.2 --flannel-iface=wg0' sh -"
echo "  3. Open UFW: sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp"
echo ""
