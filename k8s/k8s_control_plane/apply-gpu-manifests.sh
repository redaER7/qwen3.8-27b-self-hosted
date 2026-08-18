#!/usr/bin/env bash
set -euo pipefail

# Apply shared GPU manifests to the K3s cluster.
# Run this from the control plane node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Applying NVIDIA device plugin"
k3s kubectl apply -f "$SCRIPT_DIR/manifests/nvidia-device-plugin.yaml"

echo "Done"
