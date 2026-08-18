#!/usr/bin/env bash
set -euo pipefail

# GPU node K3s Agent Bootstrap
# Run this script on a fresh Trooper.ai GPU instance to join your K3s cluster.
#
# Usage:
#   export K3S_URL=https://<control-plane-ip>:6443
#   export K3S_TOKEN=<node-token>
#
# Optional env vars:
#   NODE_NAME    — explicit node name (default: trooper-ai-<hostname>-<random>)

: "${K3S_URL:?K3S_URL is required}"
: "${K3S_TOKEN:?K3S_TOKEN is required}"
: "${NODE_NAME:=gpu-node-$(hostname)}"

echo "[1/6] Installing K3s agent (v1.33.2+k3s1)"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.33.2+k3s1" \
  K3S_URL="$K3S_URL" \
  K3S_TOKEN="$K3S_TOKEN" \
  K3S_NODE_NAME="$NODE_NAME" \
  INSTALL_K3S_EXEC="agent --disable-apiserver-lb --with-node-id" \
  sh -

echo "[2/6] Waiting for node to register"
for i in $(seq 1 30); do
  if k3s kubectl get node "$NODE_NAME" &>/dev/null 2>&1; then
    break
  fi
  sleep 3
done

# Symlink K3s bundled CNI plugins to /opt/cni/bin (needed for pod sandbox networking)
CNI_SRC=/var/lib/rancher/k3s/data/current/bin
CNI_DST=/opt/cni/bin
if [ -d "$CNI_SRC" ]; then
  mkdir -p "$CNI_DST"
  for plugin in "$CNI_SRC"/*; do
    name=$(basename "$plugin")
    if [ -f "$plugin" ] && [ ! -e "$CNI_DST/$name" ]; then
      ln -sf "$plugin" "$CNI_DST/$name"
    fi
  done
fi

echo "[3/6] Installing NVIDIA container toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
nvidia-ctk --version

echo "[4/6] Writing containerd config with NVIDIA runtime"
CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
cat > "$CONFIG_FILE" << 'CONFIGEOF'
imports = ["/etc/containerd/conf.d/*.toml"]
version = 2

[plugins]

  [plugins."io.containerd.internal.v1.opt"]
    path = "/var/lib/rancher/k3s/agent/containerd"

  [plugins."io.containerd.cri.v1.images"]
    disable_snapshot_annotations = true
    snapshotter = "overlayfs"

    [plugins."io.containerd.cri.v1.images".pinned_images]
      sandbox = "rancher/mirrored-pause:3.6"

    [plugins."io.containerd.cri.v1.images".registry]
      config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"

  [plugins."io.containerd.cri.v1.runtime"]
    device_ownership_from_security_context = false
    enable_selinux = false
    enable_unprivileged_icmp = true
    enable_unprivileged_ports = true

    [plugins."io.containerd.cri.v1.runtime".cni]
      bin_dir = "/var/lib/rancher/k3s/data/cni"
      conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

    [plugins."io.containerd.cri.v1.runtime".containerd]
      default_runtime_name = "nvidia"

      [plugins."io.containerd.cri.v1.runtime".containerd.runtimes]

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/bin/nvidia-container-runtime"
            SystemdCgroup = true

        [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"

          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
            SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri"]
    stream_server_address = "127.0.0.1"
    stream_server_port = "10010"
CONFIGEOF

echo "[5/6] Restarting k3s-agent"
systemctl restart k3s-agent

if [[ -n "${MIG_PROFILES:-}" ]]; then
  echo "[5b/6] Configuring MIG partitions: $MIG_PROFILES"
  IFS=',' read -ra PROFILES <<< "$MIG_PROFILES"
  nvidia-smi mig -cgi "${PROFILES[*]}" -C
  echo "   MIG ready: $MIG_PROFILES"
fi

echo "[6/6] Creating kubeconfig for kubectl"
mkdir -p /root/.kube
k3s kubectl config view --raw > /root/.kube/config 2>/dev/null || true

echo ""
echo "========================================"
echo " Node joined cluster as: $NODE_NAME"
echo "========================================"
k3s kubectl get node "$NODE_NAME" -o wide
echo ""

# ── Manual post-bootstrap steps (run on the control plane) ──
#
#   1. Label the node:
#      kubectl label node "$NODE_NAME" \
#        node-role.kubernetes.io/gpu-node=true \
#        role=gpu
#
#   2. (Optional) Detect and label GPU model:
#      GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
#      kubectl label node "$NODE_NAME" gpu-model="$GPU_MODEL"
#
#   3. Taint so only GPU workloads schedule here:
#      kubectl taint node "$NODE_NAME" gpu-node=true:NoSchedule
