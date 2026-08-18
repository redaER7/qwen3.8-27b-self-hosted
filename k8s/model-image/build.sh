#!/usr/bin/env bash
set -euo pipefail

# Build a Docker image with model weights baked in.
#
# Usage:
#   bash build.sh [--base <image>] [--model <name>] [--tag <tag>] [--push <registry>]
#
# Examples:
#   bash build.sh --base vllm/vllm-openai:latest --model Qwen/Qwen3.8-27B --tag myregistry/vllm-with-weights:latest
#   bash build.sh --base quay.io/kserve/vllm:latest --model Qwen/Qwen3.8-27B --tag myregistry/kserve-vllm-with-weights:latest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_IMAGE="vllm/vllm-openai:latest"
MODEL_NAME="Qwen/Qwen3.8-27B"
TAG=""
REGISTRY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --base)    BASE_IMAGE="$2"; shift 2 ;;
    --model)   MODEL_NAME="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    --push)    REGISTRY="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [ -z "$TAG" ]; then
  # Derive tag from base image
  BASE_NAME=$(basename "$BASE_IMAGE" | cut -d: -f1)
  TAG="${BASE_NAME}-with-weights:latest"
fi

echo "Building with:"
echo "  BASE_IMAGE: $BASE_IMAGE"
echo "  MODEL_NAME: $MODEL_NAME"
echo "  TAG:        $TAG"

docker build \
  -t "$TAG" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg MODEL_NAME="$MODEL_NAME" \
  --secret id=hf_token,env=HF_TOKEN \
  -f "$SCRIPT_DIR/Dockerfile" \
  "$SCRIPT_DIR"

echo ""
echo "Built: $TAG"

if [ -n "$REGISTRY" ]; then
  docker tag "$TAG" "$REGISTRY/$TAG"
  docker push "$REGISTRY/$TAG"
  echo "Pushed: $REGISTRY/$TAG"
fi
