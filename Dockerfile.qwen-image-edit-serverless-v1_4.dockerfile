# Dockerfile.qwen-image-edit-serverless-v1_4
# Qwen-Image-Edit-2511 (Unsloth GGUF) on RunPod Serverless, models baked in.
#
# v1_4: no Network Volume. The Q4_K_M diffusion model, text encoder, mmproj
# and VAE (about 19.3 GB) are downloaded at build time into /opt/qwen-edit,
# using the same folder layout and filenames as the Pod volume, so existing
# workflow JSON keeps working unchanged.

# Base image: runpod/worker-comfyui, pinned to a tag that exists on Docker Hub.
# 5.10.0-base was the newest published base tag on 2026-11-16 (release 5.11.0
# exists on GitHub but has no image on Docker Hub; latest-base is from March).
# The base tag IS your ComfyUI pin (replaces COMFYUI_PINNED_COMMIT).
FROM runpod/worker-comfyui:5.10.0-base

# ComfyUI-GGUF node, pinned to the commit that built cleanly in Actions run #2
# (2026-11-16). Override with --build-arg GGUF_NODE_COMMIT=... to move it;
# set it empty to track the default branch at build time.
ARG GGUF_NODE_COMMIT=6ea2651e7df66d7585f6ffee804b20e92fb38b8a

RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF \
 && if [ -n "$GGUF_NODE_COMMIT" ]; then git -C /comfyui/custom_nodes/ComfyUI-GGUF checkout "$GGUF_NODE_COMMIT"; fi \
 && git -C /comfyui/custom_nodes/ComfyUI-GGUF rev-parse HEAD \
 && pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt

# ---------------------------------------------------------------------------
# Baked models. Same paths and filenames the Pod start script uses under
# /workspace/qwen-edit, so the workflow JSON does not change.
# One layer per file keeps each upload smaller and easier to retry.
# ---------------------------------------------------------------------------
ARG MODEL_ROOT=/opt/qwen-edit/ComfyUI/models
ARG WGET_OPTS="-nv --tries=5 --waitretry=10 --retry-connrefused --timeout=60"

RUN mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae"

# Diffusion model, Q4_K_M (~12.8 GB)
RUN wget $WGET_OPTS -O "$MODEL_ROOT/diffusion_models/qwen-image-edit-2511-Q4_K_M.gguf" \
      "https://huggingface.co/unsloth/Qwen-Image-Edit-2511-GGUF/resolve/main/qwen-image-edit-2511-Q4_K_M.gguf"

# Text encoder (~4.8 GB)
RUN wget $WGET_OPTS -O "$MODEL_ROOT/text_encoders/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf" \
      "https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL.gguf"

# mmproj (~1.4 GB), renamed so the GGUF CLIP loader auto-detects it
RUN wget $WGET_OPTS -O "$MODEL_ROOT/text_encoders/Qwen2.5-VL-7B-Instruct-UD-Q4_K_XL-mmproj.gguf" \
      "https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/mmproj-BF16.gguf"

# VAE (~0.25 GB)
RUN wget $WGET_OPTS -O "$MODEL_ROOT/vae/qwen_image_vae.safetensors" \
      "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
 && ls -lh "$MODEL_ROOT"/*

# Model paths: point ComfyUI at the baked folder
RUN rm -f /comfyui/extra_model_paths.yaml
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# GPU auto-detect wrapper (runs before the base image's own start script)
COPY --chmod=0755 serverless_entrypoint.sh /opt/serverless_entrypoint.sh

# auto = nvidia-smi detection. Set a value on the endpoint to override.
# Only Q4_K_M is baked, so every GPU profile runs Q4_K_M (the entrypoint
# falls back to it automatically when a profile asks for another quant).
ENV QWEN_GPU_PROFILE=auto \
    QWEN_VOLUME_ROOT=/opt/qwen-edit

CMD ["/bin/bash", "/opt/serverless_entrypoint.sh"]
