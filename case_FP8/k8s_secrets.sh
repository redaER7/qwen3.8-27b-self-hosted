#!/usr/bin/env bash
set -euo pipefail

# Create all Kubernetes secrets and TLS certificates for case_FP8.
# Run this BEFORE k8s_deploy.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Secrets ==="

echo "Ensuring namespaces exist..."
for ns in cert-manager beta envoy-ai-gateway-system envoy-gateway-system lws-system kserve frontend; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "[1/4] Cloudflare API token (cert-manager DNS-01)"
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Registry credentials (model image pull)"
kubectl create secret docker-registry registry-credentials \
  --namespace beta \
  --docker-server=docker-registry.yacodata.com \
  --docker-username="${REGISTRY_USERNAME:?Set REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] HuggingFace token (model download)"
kubectl create secret generic hf-token \
  --namespace beta \
  --from-literal=token="${HF_TOKEN:?Set HF_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "All secrets created."
