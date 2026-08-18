ARG BASE_IMAGE=vllm/vllm-openai:latest
FROM $BASE_IMAGE

ARG MODEL_NAME=Qwen/Qwen3.8-27B

RUN pip install --no-cache-dir huggingface-hub

RUN --mount=type=secret,id=hf_token \
    HF_TOKEN=$(cat /run/secrets/hf_token) \
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download('$MODEL_NAME')"
