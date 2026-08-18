# Case FP16 — Qwen3.8-27B (Dense BF16)

Serving **Qwen/Qwen3.8-27B** — the full-precision dense checkpoint — on two A100 40GB GPUs (~80 GB total) via vLLM (tensor-parallel), fronted by KServe (LLMInferenceService) and the Envoy AI Gateway. This is the **unquantized** sibling of [case_FP8](../case_FP8/README.md): it trades GPU budget for full BF16 precision and the model's **native 262k context**.

Model-focused layout: hardware, quantization decision, and serving parameters below are all derived from what the model needs. The serving stack (Envoy AI Gateway → KServe → vLLM) is the "how"; the model and its full-precision form on ~80 GB VRAM is the "why".

---

## 1. The Model

**Qwen3.8-27B** (Qwen/Qwen3.8-27B) is a 27-billion-parameter hybrid-attention LLM:

| Property | Value |
|----------|-------|
| Parameters | ~27B |
| Hybrid attention | 48 Gated DeltaNet (linear) layers + 16 full-attention layers |
| Context window | 262144 native (extensible to 1M) |
| Modality | Multimodal — built-in vision tower (image encoder) |
| MTP draft head | Built-in, opt-in speculative decoding |
| Reasoning | Chain-of-thought (`<reasoning>` / `</reasoning>`) |
| Tool calling | Native (Qwen3 coder-style parser) |
| vLLM support | Requires vLLM ≥ 0.17.0; recipe pins `vllm/vllm-openai:qwen38` |

**Why hybrid attention matters:** 48 of 64 layers use **Gated DeltaNet**, a linear-attention variant whose KV state grows at **O(1)**. Only the 16 full-attention layers need traditional KV cache. That is what lets a 27B model run the full 262k native context — the KV cost stays manageable even unquantized.

## 2. Why BF16 (vs FP8)

This case runs the **dense BF16 checkpoint** — no quantization:

| | Dense BF16 | FP8 (case_FP8) |
|---|-----------:|---------------:|
| Download size | ~55.6 GB (51.7 GiB) | ~31 GB (~29 GiB) |
| Weights/GPU @ TP2 | ~26 GiB | ~16 GiB |
| Minimum VRAM | ~80 GB (2× A100 40GB) | ~40 GB (2× 32GB works) |
| Context @ TP2 | 262144 (native) | 32768 (configured) |
| Precision | Full BF16 | FP8 quantized |

Choose **case_FP16** when you have ~80 GB VRAM and want the full-precision model at its native 262k context. Choose [case_FP8](../case_FP8/README.md) when you have 2× 32GB GPUs — the FP8 checkpoint halves the weights to fit.

## 3. Hardware & Sizing

| | Value |
|---|---|
| GPU | 2× NVIDIA A100 40GB (80 GB total) |
| Total VRAM | 80 GB |
| Interconnect | NVLink (A100 SXM) or PCIe (PCIe variant) — P2P expected |
| Weights/GPU @ TP2 | ~26 GiB |
| Left for KV cache + activations | ~14 GiB/GPU (at util 0.90) |
| Context | 262144 (native) |

BF16 Qwen3.8-27B (~52 GiB weights) via TP2 → ~26 GiB/GPU of weights, ~14 GiB/GPU left for KV cache + activations. Because 48/64 layers are linear-attention, KV stays small even at 262k context — the remaining budget is comfortable for batch 8.

> **This does not fit 2× 32GB.** On RTX 4080 Super 32GB the dense checkpoint OOMs during weight load. Use case_FP16 only on ~80 GB VRAM nodes.

## 4. Serving Configuration

The workload is a KServe `LLMInferenceServiceConfig` (`kserve/llm-inference-service-config-workload.yaml`) running the official vLLM OpenAI server image `vllm/vllm-openai:qwen38`:

```yaml
image: vllm/vllm-openai:qwen38
command: python3 -m vllm.entrypoints.openai.api_server
args:
  - --model                Qwen/Qwen3.8-27B
  - --port                 8000
  - --host                 0.0.0.0
  - --dtype                bfloat16
  - --tensor-parallel-size 2
  - --max-model-len        262144
  - --max-num-seqs         8
  - --gpu-memory-utilization 0.90
  - --download-dir         /mnt/huggingface/models
  - --enable-prefix-caching
  - --enable-auto-tool-choice
  - --tool-call-parser     qwen3_coder
  - --reasoning-parser     qwen3
```

| Setting | Why |
|---------|-----|
| `--dtype bfloat16` | Native dtype of the dense checkpoint (no quantization) |
| `--tensor-parallel-size 2` | Splits the model across both 40GB cards |
| `--max-model-len 262144` | The model's **native** context window |
| `--max-num-seqs 8` | Concurrency; KV stays small thanks to hybrid attention |
| `--gpu-memory-utilization 0.90` | Leave ~10% for CUDA graphs + workspace |
| `--enable-prefix-caching` | Reuses KV across requests |
| `--tool-call-parser qwen3_coder` / `--reasoning-parser qwen3` | Native Qwen tool calling + reasoning extraction |

Environment: `HF_TOKEN` (from secret `hf-token`), `HF_XET_HIGH_PERFORMANCE=1`, `HF_HUB_CACHE=/mnt/huggingface/models`, `VLLM_LOGGING_LEVEL=INFO`.

Volumes:
- `dshm` — 16 Gi emptyDir `/dev/shm`
- `hf-models` — hostPath `/mnt/hf-models` → `/mnt/huggingface/models` (persists the 55.6 GB download)
- `vllm-cache` — hostPath `/mnt/vllm-cache` → `/home/.cache` (persists the vLLM torch.compile cache + Triton autotune)

**Served model name:** vLLM serves the model as **`Qwen/Qwen3.8-27B`** (derived from `--model`). Send it in the `x-ai-eg-model` header **and** the `model` body field.

## 5. How It's Served

```
Client → https://llm.yacodata.com:443
           ▼
         Envoy Gateway proxy (CP node, NodePort 30080)
           ├── TLS termination (cert-manager + Let's Encrypt)
           └── CORS (SecurityPolicy for NextChat origin)
           ▼
         AI Gateway Controller — ext-proc (model-based routing)
           ├── x-ai-eg-model: Qwen/Qwen3.8-27B → AIServiceBackend
           ├── Token metering (input/output/total)
           └── Rate limit (30 req/min)
           ▼
         AIServiceBackend → Backend → InferencePool
           ▼
         KServe internal gateway → workload service
           ▼
         vLLM pod (GPU node, hostNetwork, 10.10.0.2:8000, TP2)
```

- **KServe** (`LLMInferenceService` in namespace `beta`) manages the deployment, service, InferencePool, and routing.
- **Envoy AI Gateway** routes on the `x-ai-eg-model` header, meters tokens, and rate-limits.
- **NextChat** frontend (`chat.yacodata.com`) calls the gateway with `CUSTOM_MODELS=Qwen/Qwen3.8-27B`.

The gateway, backend, and rate-limit YAMLs in `envoy-ai-gateway/` are identical to case_FP8 except the model-name match (`Qwen/Qwen3.8-27B`).

## 6. Operational Notes

- **Cold start**: first boot downloads ~55.6 GB from HuggingFace (~10–15 min); restarts use the `hf-models` hostPath cache.
- **First-boot compile**: vLLM torch-compiles the model (~5–20 min for the full Triton kernel set). The `vllm-cache` volume persists this under `/home/.cache/vllm`, so later restarts skip it.
- `No available shared memory broadcast block found in 60 seconds` during compilation is benign — the engine is compiling, not hung. Successful startup ends with `Application startup complete`.
- The vision encoder cache initializes with a budget of 16384 tokens (multimodal encoder; expected).
- Watch for `torch.cuda.OutOfMemoryError` — the dense checkpoint fits ~80 GB with ~14 GiB/GPU headroom.

## 7. Validation

```bash
bash case_FP16/test.sh

# Quick single check through the public gateway
curl -s https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen3.8-27B" \
  -d '{"model":"Qwen/Qwen3.8-27B","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":50}'
```

Concurrent load test: [`Tests/bench_concurrent.py`](../Tests/bench_concurrent.py).

## 8. Reference — Deploying the Stack

### Requirements

- **Kubernetes Cluster** — same shared setup as case_FP8: control plane on Hetzner CX33, GPU worker joined with label `node-role.kubernetes.io/gpu-node`. See repo-level [Kubernetes Setup](../README.md#kubernetes-setup-shared-infrastructure) steps.
- **GPU (2× A100 40GB)** — see §3. The dense BF16 checkpoint requires ~80 GB VRAM.
- **Software Stack** — identical to case_FP8: K3s v1.33+, cert-manager 1.18+, Envoy Gateway v1.8+, AI Gateway Controller v1.0.0, LWS Operator v0.9+, KServe v0.18+, vLLM `vllm/vllm-openai:qwen38`.

### Install Order

Identical to case_FP8 — run [k8s_deploy.sh](k8s_deploy.sh) after [k8s_secrets.sh](k8s_secrets.sh). Full 25-step order: see [case_FP8 README §8](../case_FP8/README.md#8-reference--deploying-the-stack). The only differences are the model config (`uri: hf://Qwen/Qwen3.8-27B`, `name: Qwen/Qwen3.8-27B`), the workload args (`--dtype bfloat16`, `--max-model-len 262144`), and the gateway/rate-limit model-name match.

### WireGuard Setup

Same as case_FP8 — CP (Hetzner) and GPU node (Trooper AI) bridged via WireGuard, Flannel VXLAN over `wg0`. Full reference: [`k8s/wireguard/README.md`](../k8s/wireguard/README.md).

### Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Create all secrets + TLS certificate (run first) |
| `k8s_deploy.sh` | Deploy all infrastructure + workloads (run after secrets) |
| `envoy-ai-gateway/` | Envoy Gateway + AI Gateway resources (header match `Qwen/Qwen3.8-27B`) |
| `kserve/llm-inference-service-config-model.yaml` | Model source (`hf://Qwen/Qwen3.8-27B`, served name `Qwen/Qwen3.8-27B`) |
| `kserve/llm-inference-service-config-workload.yaml` | Workload config (vLLM image, args, resources, GPU scheduling) |
| `kserve/llm-inferenceservice.yaml` | LLMInferenceService (combines model + workload) |
| `kserve/endpoint-picker-config.yaml` | EPP scheduler scorer weights (available; wire-in at 2+ replicas) |
| `epp-scheduler/` | EPP scorer weights reference |
| `test.sh` | End-to-end validation through the public gateway |

### Quick Start

```bash
# 1. Set secrets as environment variables
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export REGISTRY_USERNAME="your-registry-user"
export REGISTRY_PASSWORD="your-registry-password"
export HF_TOKEN="your-hf-token"

# 2. Create all secrets
bash k8s_secrets.sh

# 3. Deploy everything
bash k8s_deploy.sh
```