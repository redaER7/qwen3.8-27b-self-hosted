# K8s Control Plane (Hetzner Cloud)

Single-node K3s control plane for all cases.

## Setup

### 1. Provision a Hetzner server

We use a CX33 (4 vCPU, 8 GB RAM). Any provider works.

### 2. SSH and install K3s

```bash
ssh root@<hetzner-ip>
bash k3s-install.sh
```

This outputs `K3S_URL` and `K3S_TOKEN` — use those to bootstrap GPU workers.

### 3. Open firewall ports

Ensure the Hetzner cloud firewall allows:

| Port | Source | Purpose |
|------|--------|---------|
| 6443 | 0.0.0.0/0 | K3s API server (GPU nodes join via public IP) |
| 51820/udp | 10.8.0.0/24 | WireGuard (wg-easy Docker container) |

### 4. Verify node joins

```bash
kubectl get nodes
```

Expected: control-plane node (Ready) + GPU node (Ready, role gpu-node).

### 5. Apply GPU manifests

```bash
bash apply-gpu-manifests.sh
```

## Contents

| File | Purpose |
|------|---------|
| `k3s-install.sh` | Installs K3s v1.33 on the Hetzner node (disables Traefik, ServiceLB) |
| `apply-gpu-manifests.sh` | Applies NVIDIA device plugin DaemonSet |
| `manifests/nvidia-device-plugin.yaml` | DaemonSet that registers GPUs on GPU node|
