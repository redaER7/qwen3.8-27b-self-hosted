# EPP Scheduler Configuration

The EPP (Endpoint Picker) is configured via the `endpoint-picker-config.yaml` ConfigMap in `kserve/`.

Current weights for Qwen3.8-27B-FP8:
- `prefix-cache-scorer`:  weight 2.0 — routes to pods with matching KV cache blocks
- `load-aware-scorer`:    weight 1.0 — routes to pods with shortest queue, threshold 50
- picker policy:          max-score — selects the pod with the highest combined score

With single-replica deployments the EPP is effectively a pass-through. These weights matter when scaling to 2+ replicas.

For reference, see the ConfigMap:
  case_FP8/kserve/endpoint-picker-config.yaml
