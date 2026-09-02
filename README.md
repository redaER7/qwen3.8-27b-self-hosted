# Qwen3.8-27B Self-Hosted

[![Qwen3.8-27B](https://img.shields.io/badge/model-Qwen3.8--27B-blue)](https://huggingface.co/Qwen/Qwen3.8-27B) [![vLLM](https://img.shields.io/badge/vLLM-green)](https://github.com/vllm-project/vllm) [![KServe](https://img.shields.io/badge/KServe-blue)](https://github.com/kserve/kserve) [![Envoy AI Gateway](https://img.shields.io/badge/Envoy%20AI%20Gateway-informational)](https://github.com/envoyproxy/ai-gateway) [![Self-hosted LLM](https://img.shields.io/badge/self--hosted--LLM-lightgrey)](https://github.com/redaER7/qwen3.8-27b-self-hosted)

by **[Yacodata](https://yacodata.com)**

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?style=flat-square&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/redaer7)



Self-host **Qwen/Qwen3.8-27B** — a 27B hybrid-attention LLM with 262k native context — with vLLM, KServe, and the Envoy AI Gateway. Three ways to run it:

| Option | Where | Hardware | Context |
|--------|-------|----------|---------|
| [**case_FP8**](case_FP8/README.md) | Kubernetes (KServe + Envoy AI Gateway) | 2× RTX 4080 Super 32GB (FP8, TP2) | 32768 |
| [**case_FP16**](case_FP16/README.md) | Kubernetes (KServe + Envoy AI Gateway) | 1× RTX 6000 Pro 96GB (BF16, TP1) | 262144 (native) |
| [**case_FP16_4090pro**](case_FP16_4090pro/README.md) | Kubernetes (KServe + Envoy AI Gateway) | 2× RTX 4090 Pro 48GB (BF16, TP2) | up to 262144 (context ladder) |
| [**compose**](compose/README.md) | Docker Compose (single user) | 1× ≥40GB or 2× ≥24GB GPU | 8192 default |

## The Model

**Qwen3.8-27B** is a 27-billion-parameter **hybrid-attention** model:

- **48 Gated DeltaNet (linear) layers** — KV state grows O(1), independent of sequence length
- **16 full-attention layers** — classic attention for recall
- **262144 native context** (extensible to 1M) — feasible on modest GPUs precisely because of the hybrid design
- **Multimodal** — built-in vision tower (image encoder)
- **MTP draft head** — built-in, opt-in speculative decoding
- **Reasoning + tool calling** — chain-of-thought and native Qwen tool use

Requires vLLM ≥ 0.17.0; the official [vLLM recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) pins `vllm/vllm-openai:qwen38`.

- Model card (dense BF16): [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- Model card (FP8 quant): [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8)

## FP8 vs FP16

| | Dense BF16 (case_FP16) | FP8 (case_FP8) |
|---|-----------------------:|---------------:|
| Download | ~55.6 GB | ~31 GB |
| Weights | ~52 GiB (TP1) | ~16 GiB/GPU (TP2) |
| Minimum VRAM | 96 GB (RTX 6000 Pro) | ~40 GB |
| Precision | Full BF16 | FP8 (official quant) |

The dense BF16 checkpoint (~52 GiB) does **not** fit 2× 32GB GPUs — it OOMs during weight load. The official FP8 checkpoint halves the weights and fits 2× 32GB with ~16 GiB/GPU weights and ~27.8 GiB/GPU steady state at 32768 ctx. Choose case_FP16 when you have a 96 GB GPU (e.g. RTX 6000 Pro) and want the full-precision model at native 262k context.

## Repository Layout

```
├── case_FP8/               # K8s: FP8 on 2× 32GB GPUs (active deployment)
├── case_FP16/              # K8s: dense BF16 on RTX 6000 Pro 96GB
├── case_FP16_4090pro/      # K8s: dense BF16 on 2× RTX 4090 Pro 48GB (TP2) + context ladder
├── compose/                # Standalone single-user docker-compose (vLLM + NextChat)
├── k8s/                    # Shared Kubernetes infrastructure
│   ├── k8s_control_plane/  #   K3s control plane setup
│   ├── gpu_providers/      #   GPU worker bootstrap (Trooper AI)
│   ├── wireguard/          #   CP ↔ GPU network bridge
│   ├── monitoring/         #   Prometheus + Grafana + DCGM dashboards
│   ├── model-image/        #   Optional: bake weights into a model image
│   ├── frontend/nextchat/  #   NextChat web UI deployment
│   └── hetzner-cp-node-socat.sh
└── Tests/                  # bench_concurrent.py + bench_matrix.py (context-ladder sweeps)
```

## Kubernetes Setup (shared infrastructure)

Both Kubernetes cases (`case_FP8`, `case_FP16`) share one cluster:

1. **Control plane** — K3s server on Hetzner: [`k8s/k8s_control_plane/`](k8s/k8s_control_plane/)
2. **GPU node** — K3s agent + NVIDIA runtime + device plugin: [`k8s/gpu_providers/`](k8s/gpu_providers/)
3. **WireGuard bridge** — CP ↔ GPU network (Flannel VXLAN over the tunnel): [`k8s/wireguard/`](k8s/wireguard/)

Also included: monitoring (Prometheus + Grafana + DCGM) [`k8s/monitoring/`](k8s/monitoring/), optional baked model image [`k8s/model-image/`](k8s/model-image/), NextChat frontend [`k8s/frontend/nextchat/`](k8s/frontend/nextchat/), and the `443 → 30080` socat forwarder [`k8s/hetzner-cp-node-socat.sh`](k8s/hetzner-cp-node-socat.sh).

## Quick Start

**Standalone (fastest):**
```bash
cd compose
cp .env.example .env   # set HF_TOKEN
docker compose up -d
# → http://localhost:8000 (OpenAI API), http://localhost:3000 (NextChat)
```

**Kubernetes (full stack):**
```bash
cd case_FP8
export CLOUDFLARE_API_TOKEN=... REGISTRY_USERNAME=... REGISTRY_PASSWORD=... HF_TOKEN=...
bash k8s_secrets.sh && bash k8s_deploy.sh
# → https://llm.yacodata.com/v1 (public, TLS, metered, rate-limited)
```

## Validation

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.8-27B-FP8","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":50}'
```

## License

Apache-2.0. The model is subject to [Qwen's license](https://huggingface.co/Qwen/Qwen3.8-27B); check it before commercial use.