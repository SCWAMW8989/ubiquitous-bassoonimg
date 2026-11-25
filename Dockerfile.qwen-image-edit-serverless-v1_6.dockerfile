# Dockerfile.qwen-image-edit-serverless-v1_6
# Qwen-Image-Edit-2511 (Unsloth GGUF) on RunPod Serverless, models baked in.
#
# v1_6 (LoRA support, everything from v1_5 kept):
#   - LoRA files are baked into /opt/qwen-edit/ComfyUI/models/loras, one layer
#     per file, and extra_model_paths.yaml gains a "loras:" line.
#   - First LoRA baked: Qwen-Image-Edit-2511-Lightning 4-step (bf16, ~0.85 GB).
#     With it, KSampler runs 4 steps at cfg 1.0 instead of the full count.
#   - guard_handler.py now allows LoraLoaderModelOnly, with name and strength
#     checks (see GUARD_MAX_LORAS / GUARD_MAX_LORA_STRENGTH).
#   - Workflows that do not use a LoRA run exactly as before.
#
# v1_5 (security hardening, same models and workflow as v1_4):
#   - guard_handler.py wraps the stock handler. Only the Qwen-Image-Edit node
#     types are accepted, and image sizes, names, steps and resolution are
#     capped (see the top of guard_handler.py). The iPhone Shortcut workflow
#     passes unchanged.
#   - The base image comes in as a build arg. The GitHub workflow resolves the
#     tag to its exact sha256 digest, so every build uses a known base.
#   - ComfyUI log level defaults to INFO instead of DEBUG (fewer prompt
#     details in RunPod logs).
#   - The entrypoint ignores PUBLIC_KEY (no SSH server) unless ALLOW_SSH=1.
#
# v1_4: no Network Volume. The Q4_K_M diffusion model, text encoder, mmproj
# and VAE (about 19.3 GB) are downloaded at build time into /opt/qwen-edit,
# using the same folder layout and filenames as the Pod volume, so existing
# workflow JSON keeps working unchanged.

# Base image: runpod/worker-comfyui, pinned to a tag that exists on Docker Hub.
# 5.10.0-base was the newest published base tag on 2026-11-16.
# The base tag IS your ComfyUI pin. The workflow passes tag@sha256:digest.
ARG BASE_IMAGE=runpod/worker-comfyui:5.10.0-base
FROM ${BASE_IMAGE}

# ComfyUI-GGUF node, pinned to the commit that built cleanly in Actions run #2
# (2026-11-16). Override with --build-arg GGUF_NODE_COMMIT=... to move it.
# Keep it pinned: an empty value tracks whatever the default branch holds.
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

RUN mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae" "$MODEL_ROOT/loras"

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
      "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"

# ---------------------------------------------------------------------------
# [v1_6] LoRAs. One RUN per file, same pattern as the models above.
# The file name you save here is the exact "lora_name" the workflow uses.
# File names must be plain: letters, digits, . _ - (the guard rejects others).
# ---------------------------------------------------------------------------

# Lightning 4-step LoRA (~0.85 GB). Use with KSampler steps 4, cfg 1.0.
RUN wget $WGET_OPTS -O "$MODEL_ROOT/loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors" \
      "https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"

# Your own LoRA: copy this block once per file, then fill in the two values.
# LORA_FILE_URL_HERE must be a direct download link (Hugging Face ".../resolve/main/...").
# RUN wget $WGET_OPTS -O "$MODEL_ROOT/loras/LORA_NAME_HERE.safetensors" \
#       "LORA_FILE_URL_HERE"

RUN ls -lh "$MODEL_ROOT"/*

# Model paths: point ComfyUI at the baked folder
RUN rm -f /comfyui/extra_model_paths.yaml
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# ---------------------------------------------------------------------------
# Security wrapper: start.sh runs /guard_handler.py instead of /handler.py.
# The build fails here if the base image's start.sh changes shape, so a base
# upgrade can never silently drop the guard.
# ---------------------------------------------------------------------------
COPY --chmod=0644 guard_handler.py /guard_handler.py
RUN test -f /start.sh && test -f /handler.py \
 && sed -i 's#python -u /handler.py#python -u /guard_handler.py#g' /start.sh \
 && grep -q 'python -u /guard_handler.py' /start.sh \
 && ! grep -q 'python -u /handler.py' /start.sh \
 && python -m py_compile /guard_handler.py

# GPU auto-detect wrapper (runs before the base image's own start script)
COPY --chmod=0755 serverless_entrypoint.sh /opt/serverless_entrypoint.sh

# auto = nvidia-smi detection. Set a value on the endpoint to override.
# Only Q4_K_M is baked, so every GPU profile runs Q4_K_M (the entrypoint
# falls back to it automatically when a profile asks for another quant).
ENV QWEN_GPU_PROFILE=auto \
    QWEN_VOLUME_ROOT=/opt/qwen-edit \
    COMFY_LOG_LEVEL=INFO

CMD ["/bin/bash", "/opt/serverless_entrypoint.sh"]
