# Case FP8 — Self-Hosting Qwen3.8-27B (FP8)

Serving **Qwen/Qwen3.8-27B-FP8** — a 27B hybrid-attention model with 262k native context — on two RTX 4080 Super 32GB GPUs via vLLM (tensor-parallel), fronted by KServe (LLMInferenceService) and the Envoy AI Gateway. This case is **model-focused**: the hardware, quantization, and serving parameters below are all derived from what the model needs. The serving stack (Envoy AI Gateway → KServe → vLLM) is the "how"; the model, its FP8 form, and how it fits 64 GB of VRAM is the "why".

Control plane on Hetzner CX33, GPU worker on Trooper AI. Cross-node pod networking via Flannel VXLAN over WireGuard.

---

## 1. The Model

**Qwen3.8-27B** (Qwen/Qwen3.8-27B, released alongside the Qwen3.8 series) is a 27-billion-parameter hybrid-attention LLM:

| Property | Value |
|----------|-------|
| Parameters | ~27B |
| Hybrid attention | 48 Gated DeltaNet (linear) layers + 16 full-attention layers |
| Context window | 262144 native (extensible to 1M) |
| Modality | Multimodal — built-in vision tower (image encoder) |
| MTP draft head | Built-in, opt-in speculative decoding |
| Reasoning | Chain-of-thought (`<reasoning>` / `</reasoning>`) |
| Tool calling | Native (Qwen3 coder-style parser) |
| vLLM support | Requires vLLM ≥ 0.17.0; official recipe pins `vllm/vllm-openai:qwen38` |

**Why hybrid attention matters for self-hosting:** 48 of 64 layers use **Gated DeltaNet**, a linear-attention variant whose KV state grows at **O(1)** — independent of sequence length. Only the 16 full-attention layers need traditional KV cache. Result: a 27B model runs long contexts on far less VRAM than a dense-transformer 27B, which is precisely what makes it feasible on a pair of 32GB GPUs.

The model also ships a vision tower (so it can process images), an optional MTP draft head for faster generation, and strong reasoning + tool-calling built in — all usable through the OpenAI-compatible API served here.

## 2. Why FP8

The model's dense BF16 checkpoint (`Qwen/Qwen3.8-27B`) is ~52 GiB of weights. On two 32GB GPUs at tensor-parallel=2 that is ~26 GiB/GPU of weights alone — leaving too little for KV cache, CUDA graphs, and activations. **It OOMs during weight load**, even after tuning down context (16k), batch (4), and raising memory utilization (0.95).

Qwen publishes an official **FP8** quantized checkpoint (`Qwen/Qwen3.8-27B-FP8`, ~31 GB / ~29 GiB):

| | Dense BF16 | FP8 (official) |
|---|-----------:|---------------:|
| Download size | ~55.6 GB (51.7 GiB) | ~31 GB (~29 GiB) |
| Weights/GPU @ TP2 | ~26 GiB → **OOM on 2×32GB** | ~16 GiB → fits with headroom |
| Minimum VRAM | ~80 GB (e.g. 2× A100 40GB) | ~40 GB (2× 32GB works) |

FP8 halves the weights at negligible quality cost and is the format we run here. The full-precision model remains an option if you have ~80 GB VRAM — the config is otherwise identical.

### Checkpoint layout (`Qwen/Qwen3.8-27B-FP8`)
- 64 layer shards (model weights) — ~24.4 GB
- `outside.safetensors` (vision tower) — 6.0 GB
- `mtp.safetensors` (MTP draft head) — 0.48 GB

## 3. Hardware & Sizing (measured)

| | Value |
|---|---|
| GPU | 2× NVIDIA RTX 4080 Super, 32 GiB each (sm_89) |
| Total VRAM | 64 GB |
| Interconnect | PCIe (no NVLink) → P2P disabled, all-reduce via PYNCCL |
| Weights/GPU during load | ~16 GiB (observed 15.992 GiB) |
| Steady state @ 32768 ctx / batch 8 / util 0.90 | **27.8 GiB/GPU** (observed) |
| Headroom | ~4 GiB/GPU |

Observed on `nvtop` while the model was fully loaded and idle: `27.846 Gi / 31.992 Gi` per GPU. At idle the GPUs sit at ~0% util and ~210 MHz — the memory holds weights + KV workspace; compute only engages per request.

Sizing notes:
- **No NVLink / P2P**: custom allreduce is disabled and vLLM falls back to PYNCCL; this is expected and fine for TP2.
- The hybrid attention keeps KV small even at 32768 context — this is the whole reason 64 GB is enough for a 27B with a large context window.
- Raising `max-num-seqs` or `max-model-len` trades against the remaining ~4 GiB/GPU; the current values are a safe default.

## 4. Serving Configuration

The workload is a KServe `LLMInferenceServiceConfig` (`kserve/llm-inference-service-config-workload.yaml`) running the official vLLM OpenAI server image `vllm/vllm-openai:qwen38`:

```yaml
image: vllm/vllm-openai:qwen38
command: python3 -m vllm.entrypoints.openai.api_server
args:
  - --model                Qwen/Qwen3.8-27B-FP8
  - --port                 8000
  - --host                 0.0.0.0
  - --dtype                float16
  - --tensor-parallel-size 2
  - --max-model-len        32768
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
| `--dtype float16` | Compute dtype for the FP8 checkpoint (weights stay FP8; KV/activations FP16) |
| `--tensor-parallel-size 2` | Splits the model across both 32GB cards |
| `--max-model-len 32768` | 32k context — plenty for a 27B on 64 GB; native 262k available on bigger GPUs |
| `--max-num-seqs 8` | Concurrency; bounded by the ~4 GiB/GPU KV budget |
| `--gpu-memory-utilization 0.90` | Leave ~10% for CUDA graphs + workspace |
| `--enable-prefix-caching` | Reuses KV across requests (great with reasoning/tool-calling round-trips) |
| `--tool-call-parser qwen3_coder` / `--reasoning-parser qwen3` | Native Qwen tool calling + reasoning extraction |

Environment: `HF_TOKEN` (from secret `hf-token`), `HF_XET_HIGH_PERFORMANCE=1` (fast xet downloads), `HF_HUB_CACHE=/mnt/huggingface/models`, `VLLM_LOGGING_LEVEL=INFO`.

Volumes:
- `dshm` — 16 Gi emptyDir `/dev/shm` (distributed comms)
- `hf-models` — hostPath `/mnt/hf-models` → `/mnt/huggingface/models` (persists weights across restarts)
- `vllm-cache` — hostPath `/mnt/vllm-cache` → `/home/.cache` (persists vLLM torch.compile cache + Triton autotune — see §6)

**Served model name:** vLLM serves the model as **`Qwen/Qwen3.8-27B-FP8`** (derived from `--model`). The gateway routes and rate-limit are keyed to this exact name — send it in the `x-ai-eg-model` header **and** the `model` body field.

## 5. How It's Served

```
Client → https://llm.yacodata.com:443
           │
           ▼
         Envoy Gateway proxy (CP node, NodePort 30080)
           ├── TLS termination (cert-manager + Let's Encrypt)
           ├── CORS (SecurityPolicy for NextChat origin)
           ▼
         AI Gateway Controller — ext-proc (model-based routing)
           ├── x-ai-eg-model: Qwen/Qwen3.8-27B-FP8 → AIServiceBackend
           ├── Token metering (input/output/total)
           └── Rate limit (30 req/min, keyed to the model)
           ▼
         AIServiceBackend → Backend → InferencePool
           ▼
         KServe internal gateway → workload service
           ▼
         vLLM pod (GPU node, hostNetwork, 10.10.0.2:8000, TP2)
```

- **KServe** (`LLMInferenceService` in namespace `beta`) manages the deployment, service, InferencePool, and routing for the vLLM worker.
- **Envoy AI Gateway** routes on the `x-ai-eg-model` header, meters tokens, and rate-limits — the public single entry point.
- **NextChat** frontend (`chat.yacodata.com`) calls the gateway directly from the browser with `CUSTOM_MODELS=Qwen/Qwen3.8-27B-FP8`.

### Why not just a plain vLLM Deployment?
| Aspect | Plain vLLM Deployment | This case (KServe + Envoy AI Gateway) |
|--------|----------------------|----------------------------------------|
| Lifecycle | Manual Deployment | LLMInferenceService CRD |
| Model routing | Manual Service/HTTPRoute | InferencePool + `x-ai-eg-model` header |
| Token metering | None | Enabled |
| Rate limiting | None | 30 req/min |
| Model updates | Edit Deployment YAML | Edit LLMInferenceServiceConfig |
| Cache-aware routing | None | Available (EPP scorer config, wire-in at 2+ replicas) |

## 6. Operational Notes

- **Cold start**: first boot downloads ~31 GB from HuggingFace (~10–15 min); subsequent restarts use the `hf-models` hostPath cache (~10 s).
- **First-boot compile**: vLLM torch-compiles the model — the Dynamo bytecode transform alone takes ~29 s and full Triton kernel compilation 5–20 min. The `vllm-cache` volume persists this under `/home/.cache/vllm`, so **later restarts skip the compile**.
- The repeated `No available shared memory broadcast block found in 60 seconds` log lines during compilation are **benign** — the engine is busy compiling, not hung. Successful startup ends with `Application startup complete`.
- **No `--enforce-eager`**: CUDA graphs work fine with FP8 on sm_89; keep them on for throughput.
- Watch for real failures via `torch.cuda.OutOfMemoryError`; the model fits at 27.8 GiB/GPU steady state with ~4 GiB headroom.
- **Large request bodies**: the AI Gateway ext-proc buffers the full request body, and Envoy Gateway's default downstream per-connection buffer is only 32 KiB — bigger payloads (e.g. a benchmark harness sending long prompts) fail with `413 Payload Too Large`. `envoy-ai-gateway/client-traffic-policy.yaml` raises it to 32 MiB; the rate-limit BackendTrafficPolicy likewise raises the upstream buffer (large non-streaming responses). Tune `bufferLimit` if you send even bigger payloads.

## 7. Validation

```bash
# Full suite (5 tests) — requires jq, kubectl access to the cluster
bash case_FP8/test.sh

# Quick single check through the public gateway
curl -s https://llm.yacodata.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-ai-eg-model: Qwen/Qwen3.8-27B-FP8" \
  -d '{"model":"Qwen/Qwen3.8-27B-FP8","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":50}'
```

Concurrent load test: [`Tests/bench_concurrent.py`](../Tests/bench_concurrent.py) (`MODEL="Qwen/Qwen3.8-27B-FP8"` served name), `MAX_TOKENS_MAX=1800`. Measured results in [§8](#8-load-test-results-measured).

## 8. Load Test Results (measured)

Public gateway load test with [`Tests/bench_concurrent.py`](../Tests/bench_concurrent.py):

- **Load**: 10 concurrent requests to `https://llm.yacodata.com/v1/chat/completions`
- **Model**: `Qwen/Qwen3.8-27B-FP8`
- **TTFT probes**: 5 · **max_tokens**: 300–1800

```
─ TTFT (streaming) ─────────────────────────────────────
  # 1  TTFT = 0.98s
  # 2  TTFT = 0.97s
  # 3  TTFT = 0.96s
  # 4  TTFT = 0.68s
  # 5  TTFT = 0.98s

  TTFT: min 0.7s  p50 1.0s  p95 1.0s  max 1.0s

─ Throughput (non-streaming) ───────────────────────────
 #  max_tok  duration  tokens     tok/s  status
───────────────────────────────────────────────
 1     1249      41.8s    1249      29.9     200
 2     1081      49.7s    1081      21.8     200
 3     1034      15.1s     422      27.9     200
 4     1214      21.0s     594      28.3     200
 5      413      14.7s     413      28.1     200
 6      454      16.3s     454      27.8     200
 7      677      28.8s     415      14.4     200
 8      650      23.2s     650      28.1     200
 9     1626      53.8s    1626      30.2     200
10     1042      35.6s    1042      29.3     200

─ Summary ──────────────────────────────────────────────
  Success:  10/10  (100%)  |  0 errors
  Throughput:  0.2 req/s  |  148 tok/s
  Latency:     min 14.7s  p50 28.8s  p95 53.8s  max 53.8s
  Tokens/req:  min 413  p50 650  p95 1626  max 1626
  Tok/s:       min 14.4  p50 28.1  p95 30.2  max 30.2
```

Takeaways: first-token latency is ~1 s at full concurrency; per-stream decode holds ~28 tok/s with a few outliers on longer generations (rows 2, 7); aggregate throughput 148 tok/s across 10 parallel streams.

## 9. Reference — Deploying the Stack

### Requirements

#### Kubernetes Cluster
Same K3s setup as the shared infrastructure: control plane on Hetzner CX33 (4 vCPU / 8 GB RAM), GPU worker joined as a K3s agent with label `node-role.kubernetes.io/gpu-node`. See the repo-level [Kubernetes Setup](../README.md#kubernetes-setup-shared-infrastructure) steps.

#### GPU (Trooper AI — 2× RTX 4080 Super 32GB)
See §3. Summary: FP8 Qwen3.8-27B via TP2 → ~16 GiB weights/GPU, 27.8 GiB/GPU steady state at 32768 ctx. The dense BF16 checkpoint requires ~80 GB VRAM (e.g. 2× A100 40GB).

#### Software Stack
| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.33+ | Lightweight K8s; Flannel VXLAN over WireGuard |
| cert-manager | 1.18+ | Webhook certificates + Let's Encrypt (DNS-01 Cloudflare) |
| Envoy Gateway | v1.8+ | Gateway API provider; proxy pods on CP node |
| AI Gateway Controller (Helm) | v1.0.0 | AI routing, token metering, rate limiting |
| LWS Operator | v0.9+ | LeaderWorkerSet (KServe dependency) |
| KServe | v0.18+ | LLMInferenceService CRD |
| vLLM | `vllm/vllm-openai:qwen38` | Qwen3.8-27B recipe image (vLLM ≥ 0.17) |

### Install Order

Deployment is fully automated by [k8s_deploy.sh](k8s_deploy.sh) (run after [k8s_secrets.sh](k8s_secrets.sh)):

1. **K3s** — Hetzner CP + Trooper AI GPU agent
2. **WireGuard tunnel** — bridge CP and GPU networks (see [WireGuard setup](#wireguard-setup))
3. **cert-manager** — webhook certificates; creates `envoy-tls-cert` + `chat-tls-cert` (Let's Encrypt DNS-01 via Cloudflare)
4. **AI Gateway CRDs (Helm)** — AIGatewayRoute CRDs
5. **Envoy Gateway (Helm)** — Gateway API provider; proxy pods on CP node
6. **AI Gateway Controller (Helm)** — AI routing, token metering, rate limiting
7. **GatewayClass + EnvoyProxy + Gateway** — HTTPS listener referencing the cert-manager certificate
8. **LWS Operator + KServe (monolithic)** — LeaderWorkerSet + LLMInferenceService CRD
9. **8a — Built-in LLMInferenceServiceConfigs** — EPP scheduler, router, worker templates
10. **8b — Gateway API Inference Extension CRDs** — `InferencePool` CRD
11. **8c — Enable InferencePool in Envoy Gateway** — apply addon values + restart EG
12. **Re-apply Gateways + KServe ingress gateway** — after KServe/IEP CRDs are present
13. **Patch Envoy proxy service → NodePort 30080** — expose `ai-gateway` externally
14. **kube-prometheus-stack** — Prometheus + Grafana + node_exporter (monitoring namespace)
15. **ServiceMonitors** — scrape vLLM + Envoy proxy metrics
16. **DCGM Exporter** — GPU metrics on GPU node (with ServiceMonitor)
17. **Grafana dashboards** — vLLM, Envoy Gateway, DCGM ConfigMaps (auto-imported)
18. **KServe configs** — endpoint-picker + model + workload LLMInferenceServiceConfigs
19. **LLMInferenceService** — model + workload combined
20. **Backend + AIServiceBackend** — Backend points to the InferencePool created by LLMInferenceService
21. **AIGatewayRoute** — header match `x-ai-eg-model: Qwen/Qwen3.8-27B-FP8`
22. **Rate limiting** — BackendTrafficPolicy (30 req/min)
23. **CORS policy** — allow NextChat origin to call Envoy Gateway
24. **NextChat frontend + HTTPRoute** — UI on CP node + route through `ai-gateway`
25. **Set DNS A records** — `llm.yacodata.com` + `chat.yacodata.com` → Hetzner CP public IP

### WireGuard Setup

Required when CP and GPU nodes are on different networks (Hetzner + Trooper AI). Skip if all nodes share a LAN — Flannel VXLAN works natively.

> Full reference — setup scripts, multi-GPU ports, firewall rules, troubleshooting: [`wireguard/README.md`](../k8s/wireguard/README.md).

Flannel uses VXLAN (`UDP 8472`) for pod-to-pod networking across nodes. The CP reaches the GPU node's WireGuard IP (`10.10.0.2`) through the tunnel:

```
CP node (Hetzner)                GPU node (Trooper AI)
┌────────────────────┐          ┌────────────────────┐
│ wg0 (10.10.0.1) ────┼─ tunnel ─┼─→ wg0 (10.10.0.2) │
│                    │ UDP 51820│                    │
│ Flannel iface: wg0 │          │ Flannel iface: wg0 │
└────────────────────┘          └────────────────────┘
```

**Step 1 — CP node (Hetzner):**
```bash
bash wireguard/cp-wireguard-setup.sh
```
Creates the server key, starts WireGuard, prints the server public key. Open **port 51820/udp** in the Hetzner firewall.

**Step 2 — GPU node (Trooper AI):**
```bash
export CP_NODE_IP=<CP_PUBLIC_IP>
bash wireguard/gpu-wireguard-setup.sh
```
Generates a client key, prompts for the CP public key, starts the tunnel, prints the GPU client public key. Then on the CP:
```bash
sudo sed -i '/^# \[Peer\]/a PublicKey = <paste-GPU-public-key>\nAllowedIPs = 10.10.0.2/32' /etc/wireguard/wg0.conf
sudo systemctl restart wg-quick@wg0
```

**Step 3 — Bind Flannel to wg0 (GPU node):**
```bash
echo "flannel-iface: wg0" >> /etc/rancher/k3s/config.yaml
echo "node-ip: 10.10.0.2" >> /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s-agent
```

**Step 4 — Verify (CP node):** `ping -c 3 10.10.0.2` (~31 ms Hetzner ↔ Trooper AI).

Firewall reference (GPU node): `29817–29836` UDP (WireGuard inbound), `8472` UDP (Flannel VXLAN), `10250` TCP (Kubelet).

### Contents

| File / Dir | Purpose |
|------------|---------|
| `k8s_secrets.sh` | Create all secrets + TLS certificate (run first) |
| `k8s_deploy.sh` | Deploy all infrastructure + workloads (run after secrets) |
| `envoy-ai-gateway/gatewayclass.yaml` | GatewayClass (references Envoy Gateway controller) |
| `envoy-ai-gateway/gateway.yaml` | Gateway resource (HTTPS listener, TLS termination, KServe label) |
| `envoy-ai-gateway/kserve-gateway.yaml` | KServe internal Gateway + EnvoyProxy (CP node, ClusterIP) |
| `envoy-ai-gateway/certificate.yaml` | ClusterIssuer + Certificate (Let's Encrypt DNS-01 via Cloudflare) |
| `envoy-ai-gateway/envoyproxy.yaml` | EnvoyProxy (CP node scheduling, NodePort service) |
| `envoy-ai-gateway/envoy-gateway-values.yaml` | EG Helm values (proxy config) |
| `envoy-ai-gateway/envoy-gateway-values-addon.yaml` | EG addon values (enable InferencePool) |
| `envoy-ai-gateway/aigatewayroute.yaml` | AIGatewayRoute (header match `Qwen/Qwen3.8-27B-FP8` → AIServiceBackend) |
| `envoy-ai-gateway/backend.yaml` | Backend + AIServiceBackend (Backend points to InferencePool) |
| `envoy-ai-gateway/cors-policy.yaml` | SecurityPolicy (CORS for NextChat origin) |
| `envoy-ai-gateway/rate-limit.yaml` | BackendTrafficPolicy (30 req/min) |
| `envoy-ai-gateway/client-traffic-policy.yaml` | ClientTrafficPolicy — downstream buffer 32 MiB (see §6) |
| `envoy-ai-gateway/httproute-nextchat.yaml` | HTTPRoute routing `chat.yacodata.com` → NextChat |
| `kserve/llm-inference-service-config-model.yaml` | Model source (HF repo + served model name) |
| `kserve/llm-inference-service-config-workload.yaml` | Workload config (vLLM image, args, resources, GPU scheduling) |
| `kserve/llm-inferenceservice.yaml` | LLMInferenceService (combines model + workload) |
| `kserve/endpoint-picker-config.yaml` | EPP scheduler scorer weights (available but not wired; see `llm-inferenceservice.yaml` commented block) |
| `epp-scheduler/` | EPP scorer weights reference |

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