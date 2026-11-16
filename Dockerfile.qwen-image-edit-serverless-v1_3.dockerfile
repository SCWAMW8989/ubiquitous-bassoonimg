# Base image: runpod/worker-comfyui, pinned to a tag that exists on Docker Hub.
# 5.10.0-base was the newest published base tag on 2026-11-16 (release 5.11.0
# exists on GitHub but has no image on Docker Hub; latest-base is from March).
# The base tag IS your ComfyUI pin (replaces COMFYUI_PINNED_COMMIT).
FROM runpod/worker-comfyui:5.10.0-base

# Pin the GGUF node once you have a known-good commit (replaces GGUF_NODE_PINNED_COMMIT).
# Leave empty to track the default branch at build time.
ARG GGUF_NODE_COMMIT=

RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF \
 && if [ -n "$GGUF_NODE_COMMIT" ]; then git -C /comfyui/custom_nodes/ComfyUI-GGUF checkout "$GGUF_NODE_COMMIT"; fi \
 && git -C /comfyui/custom_nodes/ComfyUI-GGUF rev-parse HEAD \
 && pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt

# Model paths: models stay on the network volume
RUN rm -f /comfyui/extra_model_paths.yaml
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# GPU auto-detect wrapper (runs before the base image's own start script)
COPY --chmod=0755 serverless_entrypoint.sh /opt/serverless_entrypoint.sh

# auto = nvidia-smi detection. Set a value on the endpoint to override.
ENV QWEN_GPU_PROFILE=auto \
    QWEN_VOLUME_ROOT=/runpod-volume/qwen-edit

CMD ["/bin/bash", "/opt/serverless_entrypoint.sh"]
