#!/usr/bin/env bash
# serverless_entrypoint.sh (Serverless Edition v1_4)
#
# Hands-off GPU auto-detect for Qwen-Image-Edit-2511 (Unsloth GGUF) on
# RunPod Serverless. Runs once per worker start, BEFORE the base image's
# own start script launches ComfyUI + the RunPod handler.
#
# What it does:
#   1. Picks a GPU profile (same rules as the pod entrypoint.sh):
#        - QWEN_GPU_PROFILE unset or "auto"  -> nvidia-smi detection
#        - any other value                   -> manual override, no detection
#   2. Resolves quant + lowvram from the profile (QWEN_QUANT / QWEN_LOWVRAM
#      env vars still win if you set them).
#   3. Points a stable filename, qwen-image-edit-2511-ACTIVE.gguf, at the
#      chosen quant file in the model folder (baked into the image in v1_4). The workflow JSON always
#      uses that one filename, so the client never needs to know the GPU.
#   4. Falls back to Q4_K_M (always present) if the chosen quant file is
#      not in the model folder.
#   5. Hands off to the base image's start script.

set -euo pipefail

VOL_ROOT="${QWEN_VOLUME_ROOT:-/opt/qwen-edit}"
COMFY_DIR="${COMFY_DIR:-/comfyui}"
BASE_START="${BASE_START_SCRIPT:-/start.sh}"
MODEL_DIR="$VOL_ROOT/ComfyUI/models/diffusion_models"
LOCAL_DIR="$COMFY_DIR/models/diffusion_models"
ACTIVE_NAME="qwen-image-edit-2511-ACTIVE.gguf"

# ---------------------------------------------------------------------------
# GPU detection (same thresholds as the pod guide)
#   named RTX PRO 4000 / A40 / RTX 3090 -> that profile
#   otherwise by VRAM: >= 40 GB -> a40, 20-40 GB -> rtx-pro-4000,
#   < 20 GB or unreadable -> custom (safe fallback)
# ---------------------------------------------------------------------------
detect_gpu_profile() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "WARNING: nvidia-smi not found; cannot auto-detect GPU. Falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  local gpu_line
  gpu_line="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  if [ -z "$gpu_line" ]; then
    echo "WARNING: nvidia-smi returned no data; falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  local gpu_name vram_mib
  gpu_name="$(echo "$gpu_line" | awk -F',' '{print $1}' | sed 's/^ *//;s/ *$//')"
  vram_mib="$(echo "$gpu_line" | awk -F',' '{print $2}' | sed 's/^ *//;s/ *$//')"
  echo "Detected GPU: $gpu_name (${vram_mib} MiB)" >&2

  case "$gpu_name" in
    *"RTX PRO 4000"*|*"RTX PRO4000"*) echo "rtx-pro-4000"; return ;;
    *3090*) echo "rtx-3090"; return ;;
  esac

  # A40 must be matched as a whole token, otherwise "RTX A4000" (16 GB)
  # and "RTX A4500" would be misread as an A40 and get Q5_K_M.
  if [[ "$gpu_name" =~ (^|[^A-Za-z0-9])A40($|[^0-9]) ]]; then
    echo "a40"
    return
  fi

  if ! [[ "$vram_mib" =~ ^[0-9]+$ ]]; then
    echo "WARNING: Could not parse VRAM size from nvidia-smi output; falling back to custom safe profile." >&2
    echo "custom"
    return
  fi

  if [ "$vram_mib" -ge 40960 ]; then
    echo "a40"
  elif [ "$vram_mib" -ge 20480 ]; then
    echo "rtx-pro-4000"
  else
    echo "custom"
  fi
}

GPU_PROFILE="${QWEN_GPU_PROFILE:-auto}"
if [ "$GPU_PROFILE" = "auto" ]; then
  GPU_PROFILE="$(detect_gpu_profile)"
  echo "Auto-detected QWEN_GPU_PROFILE=$GPU_PROFILE" >&2
else
  echo "QWEN_GPU_PROFILE explicitly set to '$GPU_PROFILE'; skipping auto-detect." >&2
fi

# ---------------------------------------------------------------------------
# Profile defaults (identical to the pod start_comfyui.sh)
# ---------------------------------------------------------------------------
case "$GPU_PROFILE" in
  rtx-pro-4000) DEFAULT_QUANT="q4_k_m"; DEFAULT_LOWVRAM="0"; DEFAULT_RES="1024x1024" ;;
  a40)          DEFAULT_QUANT="q5_k_m"; DEFAULT_LOWVRAM="0"; DEFAULT_RES="1024x1024" ;;
  rtx-3090)     DEFAULT_QUANT="q4_k_m"; DEFAULT_LOWVRAM="0"; DEFAULT_RES="1024x1024" ;;
  custom)
    DEFAULT_QUANT="${QWEN_QUANT:-q4_k_s}"
    DEFAULT_LOWVRAM="${QWEN_LOWVRAM:-1}"
    DEFAULT_RES="${QWEN_RES:-1024x1024}"
    ;;
  *)
    echo "WARNING: Unknown QWEN_GPU_PROFILE='$GPU_PROFILE', falling back to rtx-pro-4000 defaults." >&2
    DEFAULT_QUANT="q4_k_m"; DEFAULT_LOWVRAM="0"; DEFAULT_RES="1024x1024"
    ;;
esac

export QWEN_GPU_PROFILE="$GPU_PROFILE"
export QWEN_QUANT="${QWEN_QUANT:-$DEFAULT_QUANT}"
export QWEN_LOWVRAM="${QWEN_LOWVRAM:-$DEFAULT_LOWVRAM}"
export QWEN_RES="${QWEN_RES:-$DEFAULT_RES}"

# ---------------------------------------------------------------------------
# Pick the quant file that actually exists on the volume
# ---------------------------------------------------------------------------
if [ ! -d "$MODEL_DIR" ]; then
  echo "ERROR: Model folder not found: $MODEL_DIR" >&2
  echo "       Models are baked into the image under /opt/qwen-edit. If QWEN_VOLUME_ROOT" >&2
  echo "       is set on the endpoint, remove it or point it at a folder with this layout." >&2
  exit 1
fi

QUANT_UP="${QWEN_QUANT^^}"                         # q5_k_m -> Q5_K_M
WANT_FILE="$MODEL_DIR/qwen-image-edit-2511-${QUANT_UP}.gguf"
BASELINE_FILE="$MODEL_DIR/qwen-image-edit-2511-Q4_K_M.gguf"

if [ -f "$WANT_FILE" ]; then
  CHOSEN="$WANT_FILE"
elif [ -f "$BASELINE_FILE" ]; then
  echo "NOTE: $(basename "$WANT_FILE") is not in this image; using the baked Q4_K_M." >&2
  CHOSEN="$BASELINE_FILE"
else
  echo "ERROR: Neither the requested quant nor the Q4_K_M baseline exists in $MODEL_DIR" >&2
  ls -la "$MODEL_DIR" >&2 || true
  exit 1
fi

mkdir -p "$LOCAL_DIR"
ln -sfn "$CHOSEN" "$LOCAL_DIR/$ACTIVE_NAME"
if [ ! -r "$LOCAL_DIR/$ACTIVE_NAME" ]; then
  echo "ERROR: ACTIVE model link is not readable: $LOCAL_DIR/$ACTIVE_NAME" >&2
  exit 1
fi

echo "=== Qwen-Image-Edit-2511 Serverless Worker ===" >&2
echo " GPU profile  : $QWEN_GPU_PROFILE" >&2
echo " Quant wanted : $QWEN_QUANT" >&2
echo " Model in use : $(basename "$CHOSEN") (as $ACTIVE_NAME)" >&2
echo " LowVRAM mode : $QWEN_LOWVRAM" >&2
echo " Target res   : $QWEN_RES" >&2
echo "==============================================" >&2

# ---------------------------------------------------------------------------
# Least privilege: nothing downloads at runtime, so no HF credentials needed.
# ---------------------------------------------------------------------------
unset HF_TOKEN HUGGINGFACE_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

# ---------------------------------------------------------------------------
# Hand off to the base image's start script (optionally with --lowvram)
# ---------------------------------------------------------------------------
if [ ! -f "$BASE_START" ]; then
  echo "ERROR: Base start script not found: $BASE_START" >&2
  echo "       Check the base image's CMD (docker inspect) and set BASE_START_SCRIPT." >&2
  exit 1
fi

START="$BASE_START"
if [ "$QWEN_LOWVRAM" = "1" ]; then
  if grep -q 'main\.py' "$BASE_START"; then
    PATCHED="$(mktemp /tmp/start_lowvram.XXXXXX.sh)"
    sed 's#main\.py#main.py --lowvram#g' "$BASE_START" > "$PATCHED"
    if grep -q -- '--lowvram' "$PATCHED"; then
      START="$PATCHED"
      echo " Launching ComfyUI with --lowvram (patched copy of $BASE_START)" >&2
    else
      echo "WARNING: could not apply --lowvram to $BASE_START; continuing without it." >&2
    fi
  else
    echo "WARNING: $BASE_START does not reference main.py; cannot add --lowvram. Continuing without it." >&2
  fi
fi

exec /bin/bash "$START"
