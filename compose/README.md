# Compose — Standalone Qwen3.8-27B-FP8 for a Single User

Run **Qwen/Qwen3.8-27B-FP8** on your own workstation with Docker Compose — no Kubernetes. Two services:

- **vllm** — the model, OpenAI-compatible API on `http://localhost:8000`
- **nextchat** — a ChatGPT-style web UI on `http://localhost:3000` (points at vLLM)

This is the lightweight, single-user version of the [case_FP8](../case_FP8/README.md) Kubernetes deployment. The same vLLM image (`vllm/vllm-openai:qwen38`) and the same model.

## Requirements

- **Docker** with the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed (`nvidia-ctk runtime configure --runtime=docker`, then restart Docker).
- **NVIDIA GPU(s)** — the FP8 checkpoint is ~29 GiB at tensor-parallel=1:

| GPUs | Config | Typical cards |
|------|--------|---------------|
| 1× ≥40 GB | `TP_SIZE=1` (default) | RTX 6000 Pro 96GB, A100 40GB, A6000 48GB, H100 |
| 2× ≥24 GB | `TP_SIZE=2`, `GPU_COUNT=2` | 2× RTX 4090/3090, 2× RTX 4080 Super |

> A single 24 GB card (RTX 4090/3090) does **not** hold the FP8 weights at TP1 (~29 GiB) — use two cards with `TP_SIZE=2` (weights drop to ~16 GiB/GPU).

## Quick Start

```bash
cd compose
cp .env.example .env      # then set HF_TOKEN=<your HuggingFace read token>
docker compose up -d      # first boot downloads ~31 GB + compiles (~10-20 min)
```

- vLLM: `http://localhost:8000` — `/v1/models`, `/v1/chat/completions`
- NextChat: `http://localhost:3000` (password = `NEXTCHAT_CODE`)

## Smoke Test

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3.8-27B-FP8","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":50}'
```

## Configuration (.env)

| Variable | Default | Meaning |
|----------|---------|---------|
| `HF_TOKEN` | — (required) | HuggingFace read token for the checkpoint |
| `MODEL_ID` | `Qwen/Qwen3.8-27B-FP8` | HF model / checkpoint to load |
| `MODEL_NAME` | `Qwen/Qwen3.8-27B-FP8` | Served model name (API + NextChat) |
| `DTYPE` | `float16` | Compute dtype (weights stay FP8) |
| `TP_SIZE` | `1` | Tensor-parallel size (2 for two GPUs) |
| `GPU_COUNT` | `1` | GPUs to reserve |
| `MAX_MODEL_LEN` | `8192` | Context length (lower on smaller VRAM) |
| `MAX_NUM_SEQS` | `4` | Max concurrent requests |
| `GPU_MEMORY_UTILIZATION` | `0.95` | VRAM budget fraction |
| `NEXTCHAT_CODE` | empty | NextChat access password |

Weights persist in the `hf-models` volume; the vLLM torch.compile + Triton caches persist in `vllm-cache` (`/root/.cache`) so restarts skip the long first-boot compile.

## Notes & Troubleshooting

- **Cold start** is slow on purpose: ~31 GB download + Triton kernel compilation (~10–20 min). Subsequent starts are seconds.
- **Shared memory**: `shm_size: 16g` is set — if you see shared-memory errors, the host must have at least 16 GB of `/dev/shm` free.
- **GPU not used**: verify the toolkit with `docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi`, then `docker compose down && docker compose up -d`.
- **`No available shared memory broadcast block found in 60 seconds`** during startup is benign — the engine is compiling.
- **Switching to the dense BF16 checkpoint** (needs 96 GB VRAM, e.g. RTX 6000 Pro): set `MODEL_ID=Qwen/Qwen3.8-27B`, `MODEL_NAME=Qwen/Qwen3.8-27B`, `DTYPE=bfloat16` — see [case_FP16](../case_FP16/README.md).
- For the full multi-user Kubernetes deployment with Envoy AI Gateway, token metering, rate limiting, and TLS: [case_FP8](../case_FP8/README.md).