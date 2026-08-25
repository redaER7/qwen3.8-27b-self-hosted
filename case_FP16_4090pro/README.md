# Case FP16-4090Pro — Qwen3.8-27B (Dense BF16, 2× RTX 4090 Pro 48GB)

Serving **Qwen/Qwen3.8-27B** — the full-precision dense checkpoint — on **2× NVIDIA RTX 4090 Pro (48 GB each, 96 GB total)** via vLLM (TP2), fronted by KServe (LLMInferenceService) and the Envoy AI Gateway. This is the budget variant of [case_FP16](../case_FP16/README.md) (planned RTX 6000 Pro 96GB, TP1): same total VRAM, same BF16 precision, split across two 48 GB cards.

---

## 1. Sizing (BF16, TP2)

| | Value |
|---|---|
| GPU | 2× RTX 4090 Pro, 48 GB each (Ada, sm_89) |
| Total VRAM | 96 GB |
| Weights/GPU @ TP2 | ~26 GiB |
| Usable/GPU @ util 0.90 | ~43.2 GiB |
| KV headroom/GPU | ~17 GiB (~34 GiB total) |
| KV@262k total | ~16 GiB → ~8 GiB/GPU at TP2 |

Native 262144 context fits with batch headroom at every tier:

| max-model-len | KV total | KV/GPU @ TP2 | Weights+KV/GPU | Verdict |
|---|---|---|---|---|
| 8192 | ~0.5 GiB | ~0.25 GiB | ~26.3 GiB | trivial |
| 32768 | ~2 GiB | ~1 GiB | ~27 GiB | easy |
| 131072 | ~8 GiB | ~4 GiB | ~30 GiB | fits |
| 262144 | ~16 GiB | ~8 GiB | ~34 GiB | fits (43.2 usable) |

## 2. Caveats vs RTX 6000 Pro (TP1)

1. **No NVLink** — consumer boards are PCIe-only; custom allreduce is disabled and vLLM falls back to PYNCCL over PCIe. Works fine at TP2 (same topology as case_FP8), but per-token latency and aggregate decode will trail a single big card. Throughput must be measured before pricing (`estimate.md` break-even ≥161 tok/s for the FP16 product).
2. **Ada sm_89** — BF16 supported; FP8 also available on this architecture if a cheaper variant is ever needed.
3. **Host**: 14 cores / 144 GB RAM holds the ~55.6 GB download and TP2 weight loading comfortably.
4. **OOM fallback at 262k**: retry with `--max-num-seqs 4` before declaring a tier infeasible.

## 3. Serving Configuration

Same as case_FP16 except tensor parallelism and GPU count (`kserve/llm-inference-service-config-workload.yaml`):

```yaml
image: vllm/vllm-openai:qwen38
args:
  - --model                Qwen/Qwen3.8-27B
  - --dtype                bfloat16
  - --tensor-parallel-size 2      # ← was 1
  - --max-model-len        262144 # ← per context-ladder tier; see §4
  - --max-num-seqs         8
  - --gpu-memory-utilization 0.90
  ...
resources:
  limits:
    nvidia.com/gpu: "2"           # ← was 1
```

Infra fixes ported from case_beta (`self-host-llm-ai-inference`):
- `envoy-ai-gateway/aigatewayroute.yaml`: `timeouts.request: 300s` on the route rule (overrides controller default 60s that caused all 504s on long decodes).
- `kserve/inferenceservice-config-patch.yaml`: storage-initializer resources (cpu=4, mem=24Gi), applied by deploy step 8a + controller restart.
- `envoy-ai-gateway/rate-limit.yaml`: **100 req/min while box is bench-only** — lower to 30 req/min for production.

## 4. Context Ladder Test Protocol

Sweep `CONTEXTS = [8192, 32768, 131072, 262144]`, one deployment per tier:

```bash
# Per tier:
# 1. Set --max-model-len <CTX> in kserve/llm-inference-service-config-workload.yaml
kubectl -n beta apply -f kserve/llm-inference-service-config-workload.yaml
kubectl apply -f kserve/llm-inferenceservice.yaml
# 2. Wait for rollout (weights cached on hostPath; allow recompile time at new ctx)
kubectl -n beta get pods -w
# 3. Bench
python3 Tests/bench_matrix.py --model "Qwen/Qwen3.8-27B" \
  --contexts <CTX> [--force]
# 4. Record ctx<CTX> summary; watch DCGM in Grafana for peak GiB/GPU
```

Results land in `Tests/results/ctx{N}/` + `summary-all-contexts.log` ("best config per context" footer). Fill the unmeasured FP16 row in [`estimate.md`](../estimate.md) from these numbers.

## 5. Deploy

Identical install order to case_FP8/case_FP16 (25 steps, see [case_FP8 README §9](../case_FP8/README.md#9-reference--deploying-the-stack)):

```bash
export CLOUDFLARE_API_TOKEN=... REGISTRY_USERNAME=... REGISTRY_PASSWORD=... HF_TOKEN=...
bash k8s_secrets.sh && bash k8s_deploy.sh
```

## Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Create all secrets + TLS certificate (run first) |
| `k8s_deploy.sh` | Deploy all infrastructure + workloads (incl. step 8a storage-initializer patch) |
| `envoy-ai-gateway/` | Gateway resources (header match `Qwen/Qwen3.8-27B`, 300s route timeout, 100 req/min bench rate limit) |
| `kserve/llm-inference-service-config-workload.yaml` | vLLM TP2 workload (edit `--max-model-len` per ladder tier) |
| `kserve/inferenceservice-config-patch.yaml` | Storage-initializer resource patch (cpu=4/mem=24Gi) |
| `kserve/` | Model config, LLMInferenceService, EPP reference |
