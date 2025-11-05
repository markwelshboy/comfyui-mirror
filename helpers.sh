#!/usr/bin/env bash
# ======================================================================
# helpers.sh — Golden edition
#   - No hardcoded /workspace paths (respects COMFY_HOME/CACHE_DIR/etc.)
#   - Minimal, consistent Hugging Face vars (HF_REPO_ID, HF_REPO_TYPE, HF_TOKEN, CN_BRANCH)
#   - Clear function groups with docs
#   - Safe, idempotent, parallel node installation
#   - Bundle pull-or-build logic keyed by BUNDLE_TAG + PINS
# ======================================================================

# ----------------------------------------------------------------------
# Guard: avoid double-sourcing
# ----------------------------------------------------------------------
#if [[ -n "${HELPERS_SH_LOADED:-}" ]]; then
#  return 0 2>/dev/null || exit 0
#fi
#HELPERS_SH_LOADED=0
shopt -s extglob

# ----------------------------------------------------------------------
# Expected environment (usually set in .env)
# ----------------------------------------------------------------------
# Required (paths):
#   COMFY_HOME           - e.g. /workspace/ComfyUI
#   CUSTOM_DIR           - usually "$COMFY_HOME/custom_nodes"
#   CACHE_DIR            - e.g. "$COMFY_HOME/cache"
#   CUSTOM_LOG_DIR       - e.g. "$COMFY_HOME/logs/custom_nodes"
#   BUNDLES_DIR          - e.g. "$COMFY_HOME/bundles"
# Required (python):
#   PY, PIP              - venv python/pip
# Optional (misc tooling):
#   REPO_URL             - ComfyUI repo URL (default comfyanonymous/ComfyUI)
#   GIT_DEPTH            - default 1
#   MAX_NODE_JOBS        - default 6..8
# Optional (SageAttention build):
#   SAGE_COMMIT, SAGE_GENCODE, TORCH_CUDA_ARCH_LIST, NVCC_APPEND_FLAGS, EXT_PARALLEL, MAX_JOBS
# Hugging Face:
#   HF_REPO_ID           - e.g. user/comfyui-bundles
#   HF_REPO_TYPE         - dataset | model (default dataset)
#   HF_TOKEN             - auth token
#   CN_BRANCH            - default main
#   HF_API_BASE          - default https://huggingface.co
#   BUNDLE_TAG           - logical “set” name (e.g. WAN2122_Baseline)
# Pins/signature:
#   PINS                 - computed by pins_signature() if not set

# Provide reasonable fallbacks if .env forgot any
: "${REPO_URL:=https://github.com/comfyanonymous/ComfyUI}"
: "${GIT_DEPTH:=1}"
: "${MAX_NODE_JOBS:=8}"
: "${HF_API_BASE:=https://huggingface.co}"
: "${CN_BRANCH:=main}"
: "${CACHE_DIR:=${COMFY_HOME:-/tmp}/cache}"
: "${CUSTOM_LOG_DIR:=${COMFY_HOME:-/tmp}/logs/custom_nodes}"
: "${BUNDLES_DIR:=${COMFY_HOME:-/tmp}/bundles}"

PY_BIN="${PY:-/opt/venv/bin/python}"
PIP_BIN="${PIP:-/opt/venv/bin/pip}"

# ------------------------- #
#  Logging & guard helpers  #
# ------------------------- #

# log MSG
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

# die MSG
die(){ echo "FATAL: $*" >&2; exit 1; }

# ensure CMD exists or die
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

# -------------------------- #
#  Path + directory helpers  #
# -------------------------- #

ensure_dirs(){
  mkdir -p \
    "${COMFY_HOME:?}" \
    "${CUSTOM_DIR:?}" \
    "${CUSTOM_LOG_DIR:?}" \
    "${OUTPUT_DIR:?}" \
    "${CACHE_DIR:?}" \
    "${BUNDLES_DIR:?}" \
    "${COMFY_LOGS:?}"
}

# ------------------------- #
#  Workflows / Icons import #
# ------------------------- #
copy_hearmeman_assets_if_any(){
  local repo="${HEARMEMAN_REPO:-}"
  if [ -z "$repo" ]; then return 0; fi
  local tmp="${CACHE_DIR}/.hearmeman.$$"
  rm -rf "$tmp"
  git clone "$repo" "$tmp" || return 0
  # Workflows
  if [ -d "$tmp/src/workflows" ]; then
    mkdir -p "${COMFY_HOME}/workflows"
    cp -rf "$tmp/src/workflows/"* "${COMFY_HOME}/workflows/" || true
  fi
  # Icons / scripts (e.g., start.sh images)
  if [ -d "$tmp/src/assets" ]; then
    mkdir -p "${COMFY_HOME}/assets"
    cp -rf "$tmp/src/assets/"* "${COMFY_HOME}/assets/" || true
  fi
  rm -rf "$tmp"
}

# ======================================================================
# Section 1: Generic utilities
# ======================================================================

# dl: Multi-connection downloader via aria2c
dl() {
  aria2c -x16 -s16 -k1M --continue=true \
    -d "$(dirname "$2")" -o "$(basename "$2")" "$1"
}

# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB or .aria2 files
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then  # Less than 10MB
            echo "🗑️  Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    # Check for and remove .aria2 control files
    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️  Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path"  # Also remove any partial file
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    # Download without falloc (since it's not supported in your environment)
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$destination_dir" -o "$destination_file" "$url" &

    echo "Download started in background for $destination_file"
}

download_models_if_requested() {

  # Download 480p native models
  if [ "${download_480p_native_models:-false}" == "true" ]; then
    echo "Downloading 480p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors"      "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors"     "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"  "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"                                                     "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"  "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                 "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                           "$VAE_DIR/wan_2.1_vae.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"                                                       "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
  fi

  # Download 720p native models
  if [ "${download_720p_native_models:-false}" == "true" ]; then
    echo "Downloading 720p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_720p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors"      "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors"     "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"  "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"                                                     "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"  "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                 "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                           "$VAE_DIR/wan_2.1_vae.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"                                                       "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
  fi

  # Handle full download (with SDXL)
  if [ "${download_wan_fun_and_sdxl_helper:-false}" == "true" ]; then
    echo "Downloading Wan Fun 14B Model"
    download_model "https://huggingface.co/alibaba-pai/Wan2.1-Fun-14B-Control/resolve/main/diffusion_pytorch_model.safetensors" "$DIFFUSION_MODELS_DIR/diffusion_pytorch_model.safetensors"

    UNION_DIR="$COMFY/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
    mkdir -p "$UNION_DIR"
    if [ ! -f "$UNION_DIR/diffusion_pytorch_model_promax.safetensors" ]; then
      download_model "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$UNION_DIR/diffusion_pytorch_model_promax.safetensors"
    fi
  fi

  if [ "${download_wan22:-false}" == "true" ]; then
    echo "Downloading Wan 2.2"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_t2v_high_noise_14B_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"  "$DIFFUSION_MODELS_DIR/wan2.2_t2v_low_noise_14B_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_i2v_high_noise_14B_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"  "$DIFFUSION_MODELS_DIR/wan2.2_i2v_low_noise_14B_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors"            "$DIFFUSION_MODELS_DIR/wan2.2_ti2v_5B_fp16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"        "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"                                                           "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                       "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                                 "$VAE_DIR/wan_2.1_vae.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"                                                             "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
  fi

  if [ "${download_vace:-false}" == "true" ]; then
    echo "Downloading Wan 1.3B and 14B"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors"           "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors"            "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    echo "Downloading VACE 14B Model"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors"                                                 "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_14B_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors"                                                "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_1_3B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"        "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"                                                           "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                       "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                                 "$VAE_DIR/wan_2.1_vae.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"                                                             "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
  fi

  # Download Wan Animate model
  if [ "${download_wan_animate:-false}" == "true" ]; then
    echo "Downloading Wan Animate model..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors"        "$DIFFUSION_MODELS_DIR/wan2.2_animate_14B_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"                                                           "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                       "$CLIP_VISION_DIR/clip_vision_h.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                                 "$VAE_DIR/wan_2.1_vae.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors"                                                             "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"
  fi

  # Download Optimization Loras
  if [ "${download_optimization_loras:-false}" == "true" ]; then
    echo "Downloading optimization loras"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"                                       "$LORAS_DIR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"                     "$LORAS_DIR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors"  "$LORAS_DIR/wan2.2_animate_14B_relight_lora_bf16.safetensors"
    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"             "$LORAS_DIR/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/high_noise_model.safetensors"      "$LORAS_DIR/t2v_lightx2v_high_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors"       "$LORAS_DIR/t2v_lightx2v_low_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors"     "$LORAS_DIR/i2v_lightx2v_high_noise_model.safetensors"
    download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"      "$LORAS_DIR/i2v_lightx2v_low_noise_model.safetensors"
  fi

  # Download detection models for WanAnimatePreprocess
  if [ "${download_detection:-false}" == "true" ]; then
    echo "Downloading detection models..."
    download_model "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx"     "$DETECTION_DIR/yolov10m.onnx"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin"              "$DETECTION_DIR/vitpose_h_wholebody_data.bin"
    download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx"            "$DETECTION_DIR/vitpose_h_wholebody_model.onnx"
  fi

  # Keep checking until no aria2c processes are not running
  echo "⏳ Waiting for model downloads to complete..."
  while pgrep -x "aria2c" > /dev/null; do
      echo "🔽 Model Downloads still in progress..."
      sleep 5  # Check every 5 seconds
  done
  echo "✅ All requested model downloads completed."
}

# tg: Telegram notify (best-effort)
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

# need_tools_for_hf: Ensure git, git-lfs, jq available
need_tools_for_hf() {
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq git git-lfs >/dev/null 2>&1 || true
  git lfs install --system || true
}

# pins_signature: Build an identifier from numpy/cupy/opencv versions
pins_signature() {
  "$PY_BIN" - <<'PY'
import importlib, re
def v(mod, attr="__version__"):
    try:
        m = importlib.import_module(mod)
        return getattr(m, attr, "0.0.0")
    except Exception:
        return "0.0.0"

np = v("numpy")
cp = v("cupy")
try:
    import cv2 as _cv
    cv = getattr(_cv, "__version__", "0.0.0")
    if not isinstance(cv, str):
        cv = "0.0.0"
except Exception:
    cv = "0.0.0"

norm = lambda s: re.sub(r'[^0-9\.]+','-',s).replace('.','d')
print(f"np{norm(np)}_cupy{norm(cp)}_cv{norm(cv)}")
PY
}

# bundle_ts: Sorting-friendly timestamp
bundle_ts() { date +%Y%m%d-%H%M; }

# bundle_base: Canonical bundle base name (without extension)
#   $1 tag, $2 pins, [$3 ts]
bundle_base() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="${3:-$(bundle_ts)}"
  echo "custom_nodes_bundle_${tag}_${pins}_${ts}"
}

# Name helpers
manifest_name()   { echo "custom_nodes_manifest_${1:?tag}.json"; }
reqs_name()       { echo "consolidated_requirements_${1:?tag}.txt"; }
sha_name()        { echo "${1}.sha256"; }

# repo_dir_name: Stable dir name from repo URL
repo_dir_name() { basename "${1%.git}"; }

# needs_recursive: mark repos that need --recursive
needs_recursive() {
  case "$1" in
    *ComfyUI_UltimateSDUpscale*) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ======================================================================
# Section 2: ComfyUI core management
# ======================================================================

# ensure_comfy: Install or hard-reset ComfyUI at COMFY_HOME
ensure_comfy() {
  if [[ -d "$COMFY_HOME/.git" && -f "$COMFY_HOME/main.py" ]]; then
    git -C "$COMFY_HOME" fetch --depth=1 origin || true
    git -C "$COMFY_HOME" reset --hard origin/master 2>/dev/null \
      || git -C "$COMFY_HOME" reset --hard origin/main 2>/dev/null || true
  else
    rm -rf "$COMFY_HOME"
    git clone --depth=1 "$REPO_URL" "$COMFY_HOME"
  fi

  "$PIP_BIN" install -U pip wheel setuptools
  [ -f "$COMFY_HOME/requirements.txt" ] && "$PIP_BIN" install -r "$COMFY_HOME/requirements.txt" || true
  ln -sfn "$COMFY_HOME" /ComfyUI
}

# build_sage: Build SageAttention at a specific commit (expects torch dev env ready)
#   $1 commit (e.g. 68de379)
build_sage() {
  local commit="${1:?commit}"
  ( set -e
    cd /tmp
    rm -rf SageAttention
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention
    git reset --hard "$commit"

    export MAX_JOBS="${MAX_JOBS:-32}"
    export EXT_PARALLEL="${EXT_PARALLEL:-4}"
    export NVCC_APPEND_FLAGS="${NVCC_APPEND_FLAGS:---threads 8}"
    export FORCE_CUDA=1
    export CXX="${CXX:-g++}" CC="${CC:-gcc}"
    export EXTRA_NVCCFLAGS="${SAGE_GENCODE:-}"

    "$PIP_BIN" install --no-build-isolation -e .
  )
}

# ======================================================================
# Section 3: Custom node installation (parallel)
# ======================================================================

# clone_or_pull: shallow clone or fast-forward reset
clone_or_pull() {
  local repo="$1" dst="$2" recursive="$3"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --all --prune --tags --depth="${GIT_DEPTH}" || true
    git -C "$dst" reset --hard origin/main 2>/dev/null \
      || git -C "$dst" reset --hard origin/master 2>/dev/null || true
  else
    mkdir -p "$(dirname "$dst")"
    if [[ "$recursive" == "true" ]]; then
      git clone --recursive ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    else
      git clone ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    fi
  fi
}

# build_node: per-node requirements + install.py (logs to CUSTOM_LOG_DIR)
build_node() {
  local dst="${1:?dst}"
  local name log
  name="$(basename "$dst")"
  log="${CUSTOM_LOG_DIR}/${name}.log"
  {
    echo "==> [$name] $(date -Is) start"
    if [[ -f "$dst/requirements.txt" ]]; then
      "$PIP_BIN" install --no-cache-dir -r "$dst/requirements.txt" || true
    fi
    if [[ -f "$dst/install.py" ]]; then
      "$PY_BIN" "$dst/install.py" || true
    fi
    echo "==> [$name] $(date -Is) done"
  } >"$log" 2>&1
}

# resolve_nodes_list: Resolve source of truth for repo URLs into an array name
#   Usage: local -a nodes; resolve_nodes_list nodes
# resolve_nodes_list OUT_ARRAY_NAME
resolve_nodes_list() {
  local out_name="${1:-}"
  local -a out=()
  if [[ -n "${CUSTOM_NODE_LIST_FILE:-}" && -s "${CUSTOM_NODE_LIST_FILE:-}" ]]; then
    mapfile -t out < <(grep -vE '^\s*(#|$)' "$CUSTOM_NODE_LIST_FILE")
  elif [[ -n "${CUSTOM_NODE_LIST:-}" ]]; then
    # shellcheck disable=SC2206
    out=(${CUSTOM_NODE_LIST})
  else
    out=("${DEFAULT_NODES[@]}")
  fi

  # Return via nameref or print
  if [[ -n "$out_name" ]]; then
    local -n ref="$out_name"
    ref=("${out[@]}")
  else
    printf '%s\n' "${out[@]}"
  fi
}

# install_custom_nodes_set: bounded parallel installer (wait -n throttle, no FIFOs)
#   Usage: install_custom_nodes_set NODES_ARRAY_NAME
install_custom_nodes_set() {
  local src_name="${1:-}"
  local -a NODES_LIST
  if [[ -n "$src_name" ]]; then
    local -n _src="$src_name"
    NODES_LIST=("${_src[@]}")
  else
    resolve_nodes_list NODES_LIST
  fi

  echo "[custom-nodes] Installing custom nodes. Processing ${#NODES_LIST[@]} node(s)"
  mkdir -p "${CUSTOM_DIR:?}" "${CUSTOM_LOG_DIR:?}"

  # Concurrency
  local max_jobs="${MAX_NODE_JOBS:-8}"
  if ! [[ "$max_jobs" =~ ^[0-9]+$ ]] || (( max_jobs < 1 )); then max_jobs=8; fi
  echo "[custom-nodes] Using concurrency: ${max_jobs}"

  # Harden git so it never prompts (prompts can look like a 'hang')
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=/bin/echo

  local running=0
  local errs=0
  local -a pids=()

  for repo in "${NODES_LIST[@]}"; do
    [[ -n "$repo" ]] || continue
    [[ "$repo" =~ ^# ]] && continue

    # If we're at the limit, wait for one job to finish
    if (( running >= max_jobs )); then
      if ! wait -n; then errs=$((errs+1)); fi
      running=$((running-1))
    fi

    (
      set -e
      name="$(repo_dir_name "$repo")"
      dst="$CUSTOM_DIR/$name"
      rec="$(needs_recursive "$repo")"

      echo "[custom-nodes] Starting install: $name → $dst"
      mkdir -p "$dst"

      clone_or_pull "$repo" "$dst" "$rec"

      if ! build_node "$dst"; then
        echo "[custom-nodes] ❌ Install ERROR $name (see ${CUSTOM_LOG_DIR}/${name}.log)"
        exit 1
      fi

      echo "[custom-nodes] ✅ Completed install for: $name"
    ) &

    pids+=("$!")
    running=$((running+1))
  done

  echo "[custom-nodes] Waiting for parallel node installs to complete…"
  # Wait for remaining jobs
  while (( running > 0 )); do
    if ! wait -n; then errs=$((errs+1)); fi
    running=$((running-1))
  done

  if (( errs > 0 )); then
    echo "[custom-nodes] ❌ Completed with ${errs} error(s). Check logs: $CUSTOM_LOG_DIR"
    return 2
  else
    echo "[custom-nodes] ✅ All nodes installed successfully."
  fi
}

# ======================================================================
# Section 4: Bundling (create/push/pull)
# ======================================================================

# hf_remote_url: builds authenticated HTTPS remote for model/dataset repos
hf_remote_url() {
  : "${HF_TOKEN:?missing HF_TOKEN}" "${HF_REPO_ID:?missing HF_REPO_ID}"
  local host="huggingface.co"
  [ "${HF_REPO_TYPE:-dataset}" = "dataset" ] && host="${host}/datasets"
  echo "https://oauth2:${HF_TOKEN}@${host}/${HF_REPO_ID}.git"
}

# hf_fetch_nodes_list: optionally fetch a custom_nodes.txt index from HF
#   echoes local path or empty if not present
hf_fetch_nodes_list() {
  local out="${CACHE_DIR}/custom_nodes.txt"
  mkdir -p "$CACHE_DIR"
  local url="${HF_API_BASE}/${HF_REPO_ID}/resolve/${CN_BRANCH}/custom_nodes.txt"
  if curl -fsSL -H "Authorization: Bearer ${HF_TOKEN:-}" "$url" -o "$out"; then
    echo "$out"
  else
    echo ""
  fi
}

# hf_push_files: stage tgz/sha/manifest/requirements into bundles/meta/requirements
hf_push_files() {
  local msg="${1:-update bundles}"; shift || true
  local files=( "$@" )
  local tmp="${CACHE_DIR}/.hf_push.$$"
  rm -rf "$tmp"
  git lfs install
  git clone "$(hf_remote_url)" "$tmp"
  ( cd "$tmp"
    git checkout "$CN_BRANCH" 2>/dev/null || git checkout -b "$CN_BRANCH"
    mkdir -p bundles meta requirements
    for f in "${files[@]}"; do
      case "$f" in
        *.tgz|*.sha256) cp -f "$f" bundles/ ;;
        *.json)         cp -f "$f" meta/ ;;
        *.txt)          cp -f "$f" requirements/ ;;
        *)              cp -f "$f" bundles/ ;;
      esac
    done
    git lfs track "bundles/*.tgz"
    git add .gitattributes bundles meta requirements
    git commit -m "$msg" || true
    git push origin "$CN_BRANCH"
  )
  rm -rf "$tmp"
}

# hf_fetch_latest_bundle: pull newest matching bundle for tag+pins into CACHE_DIR
#   echoes local tgz path or empty
hf_fetch_latest_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}"
  local tmp="${CACHE_DIR}/.hf_pull.$$"
  mkdir -p "$CACHE_DIR"; rm -rf "$tmp"
  git lfs install
  git clone --depth=1 "$(hf_remote_url)" "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 0; }
  local patt="bundles/$(bundle_base "$tag" "$pins")"; patt="${patt%_*}_*.tgz"
  local matches=()
  mapfile -t matches < <(cd "$tmp" && ls -1 $patt 2>/dev/null | sort)
  if (( ${#matches[@]} == 0 )); then rm -rf "$tmp"; return 0; fi
  local latest="${matches[-1]}"
  ( cd "$tmp"
    git lfs fetch --include="$latest" >/dev/null 2>&1 || true
    git lfs pull  --include="$latest" >/dev/null 2>&1 || true
    cp -f "$latest" "$CACHE_DIR/$(basename "$latest")"
  )
  local out="${CACHE_DIR}/$(basename "$latest")"
  rm -rf "$tmp"
  echo "$out"
}

# build_nodes_manifest: create JSON manifest of installed nodes
build_nodes_manifest() {
  local tag="${1:?tag}" out="${2:?out_json}"
  "$PY_BIN" - <<PY
import json, os, subprocess, sys
d = os.environ["CUSTOM_DIR"]
items = []
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if not os.path.isdir(p) or not os.path.isdir(os.path.join(p, ".git")):
        continue
    def run(*args):
        return subprocess.check_output(["git"," -C", p, *args], text=True).strip()
    try:
        url = subprocess.check_output(["git","-C",p,"config","--get","remote.origin.url"], text=True).strip()
    except Exception: url = ""
    try:
        ref = subprocess.check_output(["git","-C",p,"rev-parse","HEAD"], text=True).strip()
    except Exception: ref = ""
    try:
        br = subprocess.check_output(["git","-C",p,"rev-parse","--abbrev-ref","HEAD"], text=True).strip()
    except Exception: br = ""
    items.append({"name": name, "path": p, "origin": url, "branch": br, "commit": ref})
with open(sys.argv[1], "w") as f:
    json.dump({"tag": os.environ.get("BUNDLE_TAG",""), "nodes": items}, f, indent=2)
PY
}

# build_consolidated_reqs: dedupe/strip heavy pins we manage separately
build_consolidated_reqs() {
  local tag="${1:?tag}" out="${2:?out_txt}"
  local tmp; tmp="$(mktemp)"
  ( shopt -s nullglob
    for r in "$CUSTOM_DIR"/*/requirements.txt; do
      echo -e "\n# ---- $(dirname "$r")/requirements.txt ----"
      cat "$r"
    done
  ) > "$tmp"
  # Strip torch/opencv/cupy/numpy (we pin them), remove comments/empties, sort unique
  grep -vE '^(torch|torchvision|torchaudio|opencv(|-python|-contrib-python|-headless)|cupy(|-cuda.*)|numpy)\b' "$tmp" \
    | sed '/^\s*#/d;/^\s*$/d' | sort -u > "$out" || true
  rm -f "$tmp"
}

# build_custom_nodes_bundle: pack custom_nodes + metadata into CACHE_DIR, returns tgz path
build_custom_nodes_bundle() {
  local tag="${1:?tag}" pins="${2:?pins}" ts="$(bundle_ts)"
  mkdir -p "$CACHE_DIR"
  local base; base="$(bundle_base "$tag" "$pins" "$ts")"
  local tarpath="${CACHE_DIR}/${base}.tgz"
  local manifest="${CACHE_DIR}/$(manifest_name "$tag")"
  local reqs="${CACHE_DIR}/$(reqs_name "$tag")"
  local sha="${CACHE_DIR}/$(sha_name "$base")"

  build_nodes_manifest "$tag" "$manifest"
  build_consolidated_reqs "$tag" "$reqs"
  tar -C "$(dirname "$CUSTOM_DIR")" -czf "$tarpath" "$(basename "$CUSTOM_DIR")"
  sha256sum "$tarpath" > "$sha"
  echo "$tarpath"
}

# install_custom_nodes_bundle: extract tgz into parent of CUSTOM_DIR; normalize name
install_custom_nodes_bundle() {
  local tgz="${1:?tgz}"
  local parent dir; parent="$(dirname "$CUSTOM_DIR")"; dir="$(basename "$CUSTOM_DIR")"
  mkdir -p "$parent"
  tar -C "$parent" -xzf "$tgz"
  if [[ ! -d "$CUSTOM_DIR" ]]; then
    local extracted; extracted="$(tar -tzf "$tgz" | head -1 | cut -d/ -f1)"
    [[ -n "$extracted" ]] && mv -f "$parent/$extracted" "$CUSTOM_DIR"
  fi
}

# ensure_nodes_from_bundle_or_build:
#   If HF has a bundle matching BUNDLE_TAG + PINS → install it
#   Else build from NODES and optionally push a fresh bundle
ensure_nodes_from_bundle_or_build() {
  local tag="${BUNDLE_TAG:?BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  mkdir -p "$CACHE_DIR" "$CUSTOM_DIR" "$CUSTOM_LOG_DIR"

  echo "[custom-nodes] Looking for bundle tag=${tag}, pins=${pins}…"
  local tgz; tgz="$(hf_fetch_latest_bundle "$tag" "$pins")"
  if [[ -n "$tgz" && -s "$tgz" ]]; then
    echo "[custom-nodes] Found bundle: $(basename "$tgz") — installing"
    install_custom_nodes_bundle "$tgz"
    return 0
  fi

  # Resolve the list once, log how many we got, then pass it in.
  local -a RESOLVED_NODES=()
  resolve_nodes_list RESOLVED_NODES
  echo "[custom-nodes] RESOLVED_NODES count: ${#RESOLVED_NODES[@]}"
  if (( ${#RESOLVED_NODES[@]} == 0 )); then
    echo "[custom-nodes] ERROR: Node list is empty. Check CUSTOM_NODE_LIST_FILE / CUSTOM_NODE_LIST / DEFAULT_NODES."
    return 2
  fi

  install_custom_nodes_set RESOLVED_NODES || return $?

  if [[ "${PUSH_BUNDLE:-0}" = "1" ]]; then
    local base tarpath manifest reqs sha
    base="$(bundle_base "$tag" "$pins")"
    tarpath="$(build_custom_nodes_bundle "$tag" "$pins")"
    manifest="${CACHE_DIR}/$(manifest_name "$tag")"
    reqs="${CACHE_DIR}/$(reqs_name "$tag")"
    sha="${CACHE_DIR}/$(sha_name "$base")"
    echo "[custom-nodes] Pushing bundle + metadata to HF…"
    hf_push_files "bundle ${base}" "$tarpath" "$sha" "$manifest" "$reqs"
  fi
}

# push_bundle_if_requested: convenience wrapper (respects BUNDLE_TAG/PINS)
push_bundle_if_requested() {
  [[ "${PUSH_BUNDLE:-0}" = "1" ]] || return 0
  local tag="${BUNDLE_TAG:?BUNDLE_TAG required}"
  local pins="${PINS:-$(pins_signature)}"
  local base tarpath manifest reqs sha
  base="$(bundle_base "$tag" "$pins")"
  tarpath="$(build_custom_nodes_bundle "$tag" "$pins")"
  manifest="${CACHE_DIR}/$(manifest_name "$tag")"
  reqs="${CACHE_DIR}/$(reqs_name "$tag")"
  sha="${CACHE_DIR}/$(sha_name "$base")"
  hf_push_files "bundle ${base}" "$tarpath" "$sha" "$manifest" "$reqs"
  echo "Uploaded bundle [$base]"
}

#=====================================================================
# Section 5: Aria2-Based Model Downloads (uses json manifest)
#===================================================================== 

# ---------- .env loader (optional) ----------
helpers_load_dotenv() {
  local file="${1:-.env}"
  [ -f "$file" ] || return 0
  # export all non-comment lines
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

# ---------- Internals ----------
_helpers_need() { command -v "$1" >/dev/null || { echo "Missing $1" >&2; exit 1; }; }

_helpers_tok_json() {
  if [[ -n "$ARIA2_SECRET" ]]; then printf '"token:%s",' "$ARIA2_SECRET"; fi
}

helpers_have_aria2_rpc() {
  curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":"ping","method":"aria2.getVersion","params":[]}' \
    | jq -e '.result.version?|length>0' >/dev/null 2>&1
}

helpers_start_aria2_daemon() {
  echo "▶ Starting aria2 RPC daemon…"
  aria2c \
    --enable-rpc \
    ${ARIA2_SECRET:+--rpc-secret="$ARIA2_SECRET"} \
    --rpc-listen-port="$ARIA2_PORT" \
    --rpc-listen-all=false \
    --daemon=true \
    --max-concurrent-downloads="$ARIA2_MAX_CONC" \
    --continue=true \
    --file-allocation="$ARIA2_FALLOC" \
    --summary-interval=0 \
    --show-console-readout=false \
    --console-log-level=warn \
    --log="$COMFY_LOGS/aria2.log" --log-level=notice
}

# Resolve {VARNAME} placeholders against a JSON map
helpers_resolve_placeholders() {
  local string="$1" map_json="$2"
  jq -nr --arg s "$string" --argjson map "$map_json" '
    def subvars($m):
      reduce ($m|to_entries[]) as $e ($s; gsub("\\{"+($e.key)+"\\}"; ($e.value|tostring)) );
    $s | subvars($map)
  '
}

# Quick size/partial cleanup; returns 0 if should download, 1 if skip
helpers_ensure_target_ready() {
  local full_path="$1"
  local sz
  mkdir -p "$(dirname -- "$full_path")"
  if [[ -f "$full_path" ]]; then
    sz=$(stat -c%s "$full_path" 2>/dev/null || stat -f%z "$full_path" 2>/dev/null || echo 0)
    if (( sz > 10485760 )); then
      echo "✅ $(basename -- "$full_path") exists (${sz}B), skipping."
      return 1
    else
      echo "🗑️  Deleting small/partial file: $full_path"
      rm -f -- "$full_path"
    fi
  fi
  [[ -f "${full_path}.aria2" ]] && rm -f -- "${full_path}.aria2" || true
  return 0
}

# ---------- MAIN: download selected sections from manifest ----------
helpers_download_from_manifest() {
  _helpers_need curl; _helpers_need jq; _helpers_need awk

  if [[ -z "${MODEL_MANIFEST_URL:-}" ]]; then
    echo "MODEL_MANIFEST_URL is not set." >&2
    return 1
  fi

  local MAN; MAN="$(mktemp)"
  curl -fsSL "$MODEL_MANIFEST_URL" -o "$MAN" || {
    echo "Failed to fetch manifest: $MODEL_MANIFEST_URL" >&2
    return 1
  }

  # Build placeholder map = vars + paths + current env (env can override)
  local VARS_JSON
  VARS_JSON="$(
    jq -n --slurpfile m "$MAN" '
      ($m[0].vars // {}) as $v
      | ($m[0].paths // {}) as $p
      | ($v + $p)
    '
  )"
  # Merge uppercase env into map (env wins)
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z0-9_]+$ ]] || continue
    VARS_JSON="$(jq --arg k "$k" --arg v "$v" '. + {($k):$v}' <<<"$VARS_JSON")"
  done < <(env)

  # Which sections are enabled? either export <section>=true or download_<section>=true
  local SECTIONS_ALL ENABLED sec
  SECTIONS_ALL="$(jq -r '.sections | keys[]' "$MAN")"
  ENABLED=()
  while read -r sec; do
    if [[ "${!sec:-}" == "true" || "${!sec:-}" == "1" ]]; then ENABLED+=("$sec"); fi
    local dl_var="download_${sec}"
    if [[ "${!dl_var:-}" == "true" || "${!dl_var:-}" == "1" ]]; then ENABLED+=("$sec"); fi
  done <<<"$SECTIONS_ALL"

  if ((${#ENABLED[@]}==0)); then
    echo "No sections enabled. Available:"
    echo "$SECTIONS_ALL" | sed 's/^/  - /'
    return 0
  fi
  mapfile -t ENABLED < <(printf '%s\n' "${ENABLED[@]}" | awk '!seen[$0]++')

  helpers_have_aria2_rpc || helpers_start_aria2_daemon
  helpers_reset_enqueued

  local url raw_path path dir out gid
  for sec in "${ENABLED[@]}"; do
    echo ">>> Enqueue section: $sec"

    jq -r --arg sec "$sec" --arg default_dir "${DEFAULT_DOWNLOAD_DIR:-$COMFY}" '
      # Normalize each entry to an object {url, path}
      def as_obj:
        if (type=="object") then
          {url:(.url // ""), path:(.path // ((.dir // "") + (if .out then "/" + .out else "" end)))}
        elif (type=="array") then
          {url:(.[0] // ""), path:(.[1] // "")}
        elif (type=="string") then
          {url:., path:""}
        else
          {url:"", path:""}
        end;

      (.sections[$sec] // [])[]
      | as_obj
      | .url as $u
      | ( if (.path|length) > 0 then .path
          else ( if ($default_dir|length) > 0
                then ($default_dir + "/" + ($u|sub("^.*/";"")))
                else (               ($u|sub("^.*/";"")) )
                end )
          end ) as $p
      | select(($u|type)=="string" and ($p|type)=="string" and ($u|length)>0 and ($p|length)>0)
      | [$u, $p] | @tsv
    ' "$MAN" | while IFS=$'\t' read -r url raw_path; do
          [[ -z "$url" || -z "$raw_path" ]] && { echo "⚠️  Skipping invalid item"; continue; }

          path="$(helpers_resolve_placeholders "$raw_path" "$VARS_JSON")"
          dir="$(dirname -- "$path")"
          out="$(basename -- "$path")"
          mkdir -p -- "$dir"

          if helpers_ensure_target_ready "$path"; then
            echo "📥 Queue: $(basename -- "$path")"
            gid="$(helpers_rpc_add_uri "$url" "$dir" "$out" "")"
            helpers_record_gid "$gid"
          fi
      done
  done

  echo "✅ Enqueued selected sections."
}

# ---------- Progress snapshots (append-friendly; no clear by default) ----------
helpers_progress_snapshot_loop() {
  _helpers_need curl; _helpers_need jq; _helpers_need gawk
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-5}}"
  local barw="${2:-${ARIA2_PROGRESS_BAR_WIDTH:-40}}"
  local outlog="${3:-${COMFY_LOGS:-/workspace/logs}/aria2_progress.log}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
  [[ "$barw" =~ ^[0-9]+$ ]] || barw=40
  mkdir -p "$(dirname "$outlog")"

  local keys='["gid","status","totalLength","completedLength","downloadSpeed","files"]'
  local seen_file="/tmp/.aria2_seen_completed_paths"
  touch "$seen_file"

  human_bytes(){ gawk 'function h(x){s="B KB MB GB TB PB";split(s,a," ");i=1;while(x>=1024&&i<6){x/=1024;i++}
    return (i==1?sprintf("%d %s",x,a[i]):sprintf("%.2f %s",x,a[i]))} {print h($1)}' ;}
  print_bar(){ local p="$1" w="$2"; local f=$(( (p*w)/100 )); local e=$(( w-f ))
    printf "[%s%s]" "$(printf '█%.0s' $(seq 1 $f))" "$(printf ' %.0s' $(seq 1 $e))"; }

  while :; do
    {
      echo "=== aria2 progress @ $(date '+%Y-%m-%d %H:%M:%S') ==="

      # Active jobs
      ACTIVE_JSON="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
        -H 'Content-Type: application/json' \
        --data "{ \"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"aria2.tellActive\",\"params\":[ $(_helpers_tok_json) $keys ] }")"
      local count; count="$(jq '.result|length' <<<"$ACTIVE_JSON")"
      echo "Active (${count})"
      echo "--------------------------------------------------------------------------------"

      local total_speed=0 total_done=0 total_size=0
      while IFS=$'\t' read -r status total done speed name; do
        pct=0; [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]] && pct=$(( (done*100)/total ))
        bar="$(print_bar "$pct" "$barw")"
        sh="$(printf "%s/s" "$(printf "%s" "$speed" | human_bytes)")"
        dh="$(printf "%s" "$done" | human_bytes)"
        th="$(printf "%s" "$total" | human_bytes)"
        printf "%-50.50s  %3d%% %s  %8s  (%s / %s)\n" "$(basename "$name")" "$pct" "$bar" "$sh" "$dh" "$th"
        total_speed=$(( total_speed + speed ))
        total_done=$(( total_done + done ))
        total_size=$(( total_size + total ))
      done < <(
        jq -r '
          (.result // [])
          | map({
              status,
              total: (.totalLength|tonumber? // 0),
              done:  (.completedLength|tonumber? // 0),
              speed: (.downloadSpeed|tonumber? // 0),
              name:  ( .files[0].path // (.files[0].uris[0].uri // "unknown") )
            })
          | .[]
          | [ .status, (.total|tostring), (.done|tostring), (.speed|tostring), .name ]
          | @tsv
        ' <<<"$ACTIVE_JSON"
      )

      # ---- totals already accumulated above: total_speed, total_done, total_size ----
      local sp dsum tsum
      sp="$(printf "%s/s" "$(printf "%s" "$total_speed" | human_bytes)")"
      dsum="$(printf "%s" "$total_done" | human_bytes)"
      tsum="$(printf "%s" "$total_size" | human_bytes)"
      echo "--------------------------------------------------------------------------------"
      echo "Group total: speed ${sp}, done ${dsum} / ${tsum}"

      # ETA (hh:mm:ss) using totals; guard against divide-by-zero & weirdness
      if (( total_speed > 0 && total_size > 0 )); then
        local remain eta_sec
        remain=$(( total_size - total_done ))
        (( remain < 0 )) && remain=0
        # ceil division for nicer ETA (round up to next second)
        eta_sec=$(( (remain + total_speed - 1) / total_speed ))
        printf "ETA: %02d:%02d:%02d\n" $((eta_sec/3600)) $(((eta_sec%3600)/60)) $((eta_sec%60))
      fi
      echo  
      
      # Completed section
      STOP_JSON="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
        -H 'Content-Type: application/json' \
        --data "{ \"jsonrpc\":\"2.0\",\"id\":\"s\",\"method\":\"aria2.tellStopped\",\"params\":[ $(_helpers_tok_json) 0,100,[\"gid\",\"status\",\"files\",\"totalLength\"] ] }")"
      mapfile -t NEW_DONE < <(
        jq -r '
          (.result // [])
          | map(select(.status=="complete"))
          | .[]
          | [ (.files[0].path // (.files[0].uris[0].uri // "unknown")),
              (.totalLength|tonumber? // 0) ]
          | @tsv
        ' <<<"$STOP_JSON" \
        | while IFS=$'\t' read -r fpath bytes; do
            if ! grep -Fxq -- "$fpath" "$seen_file"; then
              printf "%s\t%s\n" "$fpath" "$bytes"
              echo "$fpath" >> "$seen_file"
            fi
          done
      )
      if ((${#NEW_DONE[@]})); then
        echo "Completed (${#NEW_DONE[@]})"
        echo "--------------------------------------------------------------------------------"
        for line in "${NEW_DONE[@]}"; do
          fpath="${line%%$'\t'*}"
          bytes="${line##*$'\t'}"
          size_h="$(printf "%s" "$bytes" | human_bytes)"
          printf "✔ %-50.50s  (%s)\n" "$(basename "$fpath")" "$size_h"
        done
        echo
      fi
    } | tee -a "$outlog"

    # Exit when no active/waiting jobs remain
    active_count="$(jq '.result | length' <<<"$ACTIVE_JSON")"
    WAITING_JSON="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
      -H 'Content-Type: application/json' \
      --data "{ \"jsonrpc\":\"2.0\",\"id\":\"w\",\"method\":\"aria2.tellWaiting\",\"params\":[ $(_helpers_tok_json) 0,1, $keys ] }")"
    waiting_count="$(jq '.result | length' <<<"$WAITING_JSON")"
    if [[ "$active_count" -eq 0 && "$waiting_count" -eq 0 ]]; then
      sleep "$interval"
      ACTIVE_JSON="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
        -H 'Content-Type: application/json' \
        --data "{ \"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"aria2.tellActive\",\"params\":[ $(_helpers_tok_json) $keys ] }")"
      active_count="$(jq '.result | length' <<<"$ACTIVE_JSON")"
      WAITING_JSON="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
        -H 'Content-Type: application/json' \
        --data "{ \"jsonrpc\":\"2.0\",\"id\":\"w\",\"method\":\"aria2.tellWaiting\",\"params\":[ $(_helpers_tok_json) 0,1, $keys ] }")"
      waiting_count="$(jq '.result | length' <<<"$WAITING_JSON")"
      if [[ "$active_count" -eq 0 && "$waiting_count" -eq 0 ]]; then
        echo "All downloads are idle/finished." | tee -a "$outlog"
        break
      fi
    fi
    sleep "$interval"
  done
}

helpers_watch_gids() {
  _helpers_need jq; _helpers_need curl
  local gids=("$@")
  local -A done=()
  while :; do
    local all=1
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && continue
      s="$(curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":\"st\",\"method\":\"aria2.tellStatus\",\"params\":[ $(_helpers_tok_json) \"$g\", [\"status\",\"completedLength\",\"totalLength\",\"files\"] ] }")"
      st="$(jq -r '.result.status' <<<"$s")"
      name="$(jq -r '.result.files[0].path // .result.files[0].uris[0].uri' <<<"$s")"
      cl="$(jq -r '.result.completedLength' <<<"$s")"; tl="$(jq -r '.result.totalLength' <<<"$s")"
      printf "%-50.50s  %-9s  %s/%s\n" "$(basename "$name")" "$st" "$cl" "$tl"
      if [[ "$st" == "complete" || "$st" == "error" ]]; then done[$g]=1; fi
    done
    for g in "${gids[@]}"; do [[ ${done[$g]} ]] || { all=0; break; }; done
    (( all )) && break
    sleep "${ARIA2_PROGRESS_INTERVAL:-2}"
  done
}

helpers_rpc_shutdown() {
  curl -s "http://${ARIA2_HOST}:${ARIA2_PORT}/jsonrpc" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":\"sd\",\"method\":\"aria2.shutdown\",\"params\":[\"token:${ARIA2_SECRET}\"]}" \
    | jq -r '.result // .error.message // "ok"' 2>/dev/null
}

# Return just the host of a URL
_helpers_url_host() { awk -F/ '{print $3}' <<<"$1"; }

# HEAD/redirect probe → prints HTTP status code (or 000 on failure)
_helpers_http_status() {
  local url="$1"
  curl -sS -o /dev/null \
       -I -L \
       --max-redirs "${HF_PROBE_REDIRECTS:-5}" \
       --connect-timeout "${HF_PROBE_TIMEOUT:-5}" \
       --retry "${HF_PROBE_RETRY:-0}" \
       --write-out '%{http_code}' \
       "$url" || printf '000'
}

# Decide if this URL needs HF auth (returns 0/1 printed to stdout)
# Modes:
#   HF_AUTH_MODE=auto (default): probe; send auth only on 401/403
#   HF_AUTH_MODE=always: always attach Authorization for huggingface.co
#   HF_AUTH_MODE=never:  never attach Authorization
_helpers_hf_needs_auth() {
  local url="$1"
  local host; host="$(_helpers_url_host "$url")"
  [[ "$host" =~ (^|\.)(huggingface\.co)$ ]] || { echo 0; return; }

  case "${HF_AUTH_MODE:-auto}" in
    always) echo 1; return ;;
    never)  echo 0; return ;;
    auto|*) :
      local code; code="$(_helpers_http_status "$url")"
      # 401/403 → private/gated, needs token
      if [[ "$code" == "401" || "$code" == "403" ]]; then
        echo 1
      else
        echo 0
      fi
      ;;
  esac
}

helpers_reset_enqueued() {
  : > "$ARIA2_GID_FILE"
}

helpers_record_gid() {
  local gid="$1"
  [[ -n "$gid" && "$gid" != "null" ]] && echo "$gid" >> "$ARIA2_GID_FILE"
}

# Wait until ALL provided GIDs are complete/error/removed.
# Returns 0 if all completed OK, 1 if any ended in error/removed.
helpers_wait_for_gids() {
  _helpers_need curl; _helpers_need jq
  local interval="${1:-${PROGRESS_INTERVAL:-5}}"; shift || true
  local gids=("$@")
  [[ ${#gids[@]} -eq 0 ]] && { echo "No GIDs to wait on." >&2; return 0; }

  declare -A done ok
  while :; do
    # Build system.multicall for all not-done GIDs
    local payload='{"jsonrpc":"2.0","id":"mc","method":"system.multicall","params":[['
    local first=1
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && continue
      [[ $first -eq 0 ]] && payload+=','
      first=0
      if [[ -n "${ARIA2_SECRET:-}" ]]; then
        payload+='{"methodName":"aria2.tellStatus","params":["token:'"${ARIA2_SECRET}"'","'"$g"'",["status","errorMessage","totalLength","completedLength","files"]]}'
      else
        payload+='{"methodName":"aria2.tellStatus","params":["'"$g"'",["status","errorMessage","totalLength","completedLength","files"]]}'
      fi
    done
    payload+=']]}'

    # If nothing pending, break
    if [[ $first -eq 1 ]]; then
      break
    fi

    local resp
    resp="$(curl -s "http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc" \
            -H 'Content-Type: application/json' --data-binary "$payload")"

    local i=0
    for g in "${gids[@]}"; do
      [[ ${done[$g]} ]] && { i=$((i+1)); continue; }
      local node status errmsg
      node="$(jq -r --argjson idx "$i" '.result[$idx]' <<<"$resp")"
      if [[ "$(jq -r 'has("error")' <<<"$node")" == "true" ]]; then
        done[$g]=1; ok[$g]=0
        i=$((i+1))
        continue
      fi
      status="$(jq -r '.result.status // "unknown"' <<<"$node")"
      errmsg="$(jq -r '.result.errorMessage // ""' <<<"$node")"

      case "$status" in
        complete) done[$g]=1; ok[$g]=1 ;;
        error|removed) done[$g]=1; ok[$g]=0; [[ -n "$errmsg" ]] && echo "✖ $g error: $errmsg" >&2 ;;
        *) ;;
      esac
      i=$((i+1))
    done

    # All done?
    local all=1; for g in "${gids[@]}"; do [[ ${done[$g]} ]] || { all=0; break; }; done
    (( all )) && break

    sleep "$interval"
  done

  local any_bad=0; for g in "${gids[@]}"; do [[ "${ok[$g]}" == "1" ]] || any_bad=1; done
  return $any_bad
}

# Convenience: wait on everything recorded in $ARIA2_GID_FILE
helpers_wait_for_enqueued() {
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-5}}"
  [[ -f "$ARIA2_GID_FILE" ]] || { echo "No GID file: $ARIA2_GID_FILE" >&2; return 0; }
  mapfile -t gids < <(awk 'NF' "$ARIA2_GID_FILE" | awk '!seen[$0]++')
  helpers_wait_for_gids "$interval" "${gids[@]}"
}

# Run progress UI until specific GIDs finish, then exit
helpers_progress_until_done() {
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-5}}"; shift || true
  local gids=("$@")
  [[ ${#gids[@]} -eq 0 ]] && { echo "No GIDs to watch." >&2; return 0; }
  helpers_progress_snapshot_loop "$interval" "${ARIA2_PROGRESS_BAR_WIDTH:-40}" "${COMFY_LOGS:-/workspace/logs}/aria2_progress.log" &
  local snap_pid=$!
  helpers_wait_for_gids "$interval" "${gids[@]}"
  local rc=$?
  kill "$snap_pid" >/dev/null 2>&1 || true
  wait "$snap_pid" 2>/dev/null || true
  return $rc
}

aria2_enqueue_and_wait_from_manifest() {
  local interval="${1:-${ARIA2_PROGRESS_INTERVAL:-10}}"
  helpers_download_from_manifest

  # Pull unique gids we just enqueued
  mapfile -t gids < <(awk 'NF' "${ARIA2_GID_FILE:-/tmp/.aria2_enqueued_gids}" | awk '!seen[$0]++')

  # Run your pretty snapshot loop until those GIDs finish
  helpers_progress_until_done "$interval" "${gids[@]}"
}

# ---------- CivitAI ID downloader (via /usr/local/bin/download_with_aria.py) ----------
# Env it uses (override in .env):
: "${CHECKPOINT_IDS_TO_DOWNLOAD:=}"     # e.g. "12345, 67890"
: "${LORAS_IDS_TO_DOWNLOAD:=}"          # e.g. "abc, def ghi"
: "${CIVITAI_LOG_DIR:=${COMFY_LOGS:-/workspace/logs}/civitai}"

# Split a comma/space/newline-separated list, dedupe, echo one-per-line
_helpers_split_ids() {
  local s="${1:-}"
  # drop placeholder tokens
  s="${s//replace_with_ids/}"
  # unify separators (comma/newline->space), trim
  s="$(printf '%s' "$s" | tr ',\n' '  ' | xargs -n1 echo | sed '/^$/d')"
  # dedupe, preserve order
  awk '!seen[$0]++' <<<"$s"
}

# Run a command with a simple concurrency gate
_helpers_gate() {
  local -n _count_ref=$1
  local max="${2:-6}"
  while (( _count_ref >= max )); do
    wait -n || true
    ((_count_ref--))
  done
}

# Main entry: schedule CivitAI downloads by IDs into target dirs.
# You may pass an explicit mapping; otherwise it uses checkpoints/loras envs.
# Usage:
#   download_civitai_ids
#   download_civitai_ids "/path/A:ID1 ID2" "/path/B:ID3,ID4"
download_civitai_ids() {
  command -v download_with_aria.py >/dev/null || {
    echo "❌ /usr/local/bin/download_with_aria.py not found/executable" >&2
    return 1
  }

  declare -A map=()

  if (( $# > 0 )); then
    # Accept arguments like: "/target/dir1:IDa,IDb" "/target/dir2:IDc IDd"
    local pair dir ids
    for pair in "$@"; do
      dir="${pair%%:*}"; ids="${pair#*:}"
      map["$dir"]="$ids"
    done
  else
    # Default mapping from env
    map["$COMFY_HOME/models/checkpoints"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
    map["$COMFY_HOME/models/loras"]="$LORAS_IDS_TO_DOWNLOAD"
  fi

  local total=0 running=0 started=0 pids=()

  for TARGET_DIR in "${!map[@]}"; do
    mkdir -p "$TARGET_DIR"
    ids_raw="${map[$TARGET_DIR]}"

    # Skip empty or placeholder
    if [[ -z "${ids_raw// }" ]]; then
      echo "⏭️  No IDs set for $TARGET_DIR"
      continue
    fi

    echo "📦 Target: $TARGET_DIR"
    while IFS= read -r MODEL_ID; do
      [[ -z "$MODEL_ID" ]] && continue

      # Gate concurrency
      _helpers_gate running "$ARIA2_MAX_CONC"

      # Per-ID log
      safe_id="${MODEL_ID//[^A-Za-z0-9._-]/_}"
      logfile="${CIVITAI_LOG_DIR}/$(basename "$TARGET_DIR")_${safe_id}.log"

      (
        cd "$TARGET_DIR"
        echo "🚀 [$MODEL_ID] → $TARGET_DIR"
        # If your downloader supports API tokens, export here (example):
        # export CIVITAI_TOKEN=...
        download_with_aria.py -m "$MODEL_ID" >"$logfile" 2>&1
        rc=$?
        if (( rc == 0 )); then
          echo "✅ [$MODEL_ID] done"
        else
          echo "❌ [$MODEL_ID] failed (rc=$rc) — see $logfile"
        fi
      ) &

      pids+=($!)
      ((running++))
      ((started++))
      ((total++))
      # small jitter to avoid thundering herd
      sleep 0.2
    done < <(_helpers_split_ids "$ids_raw")
  done

  echo "📋 Scheduled ${started} download(s). Waiting…"
  # Drain remaining jobs
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  echo "✅ CivitAI batch complete. Logs: ${CIVITAI_LOG_DIR}"
}

# Size parser stays simple & jq-friendly
_helpers_parse_size_bytes() {
  local s="${1:-1M}"
  case "$s" in
    *[!0-9KkMmGg]*) printf '%s' "$s" ;;
    *K|*k) gawk -v n="${s%[Kk]}" 'BEGIN{printf "%d", n*1024}' ;;
    *M|*m) gawk -v n="${s%[Mm]}" 'BEGIN{printf "%d", n*1024*1024}' ;;
    *G|*g) gawk -v n="${s%[Gg]}" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
  esac
}

helpers_rpc_add_uri() {
  local url="$1" dir="$2" out="$3" checksum="${4:-}"

  # Concurrency knobs (global defaults)
  local split_n="${SPLIT:-16}"
  local mconn_n="${MCONN:-16}"
  local chunk_sz="${CHUNK:-1M}"

  # If host is HF, optionally downshift (gentler on their CDN)
  local host; host="$(_helpers_url_host "$url")"
  if [[ "$host" =~ (^|\.)(huggingface\.co)$ ]]; then
    split_n="${HF_SPLIT:-${split_n}}"
    mconn_n="${HF_MCONN:-${mconn_n}}"
    chunk_sz="${HF_CHUNK:-${chunk_sz}}"
  fi

  # bytes → integer for aria2 RPC
  _helpers_parse_size_bytes() {
    local s="${1:-1M}"
    case "$s" in
      *K|*k) gawk -v n="${s%[Kk]}" 'BEGIN{printf "%d", n*1024}' ;;
      *M|*m) gawk -v n="${s%[Mm]}" 'BEGIN{printf "%d", n*1024*1024}' ;;
      *G|*g) gawk -v n="${s%[Gg]}" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
      *)     printf '%s' "$s" ;;
    esac
  }
  local chunk_b; chunk_b="$(_helpers_parse_size_bytes "$chunk_sz")"

  # Decide whether to attach Authorization for this specific URL
  local send_auth; send_auth="$(_helpers_hf_needs_auth "$url")"
  if [[ "$send_auth" == "1" && -z "${HF_TOKEN:-}" ]]; then
    echo "⚠️  HF auth required by probe, but HF_TOKEN is not set. Proceeding without Authorization; may fail." >&2
    send_auth=0
  fi

  # Build per-download options
  local opt req resp gid err
  opt="$(
    jq -n \
      --arg dir "$dir" \
      --arg out "$out" \
      --arg hf "${HF_TOKEN:-}" \
      --arg chk "$checksum" \
      --arg host "$host" \
      --argjson split "$split_n" \
      --argjson mconn "$mconn_n" \
      --argjson chunk "$chunk_b" \
      --argjson send_auth "$send_auth" '
        {
          dir: $dir,
          out: $out,
          continue: true,
          split: $split,
          "max-connection-per-server": $mconn,
          "min-split-size": $chunk
        }
        | if $send_auth==1 then .header = [ "Authorization: Bearer \($hf)" ] else . end
        | if ($chk|length)>0 then .checksum=("sha-256="+$chk) else . end
      '
  )"

  req="$(
    jq -n \
      --arg url "$url" \
      --argjson opt "$opt" \
      --arg tok "${ARIA2_SECRET:-}" '
        {
          jsonrpc:"2.0",
          id:"add",
          method:"aria2.addUri",
          params: (
            ( if ($tok|length)>0 then ["token:"+$tok] else [] end )
            + [[ $url ]]
            + [ $opt ]
          )
        }'
  )"

  resp="$(
    printf '%s' "$req" \
    | curl -s "http://${ARIA2_HOST:-127.0.0.1}:${ARIA2_PORT:-6800}/jsonrpc" \
            -H 'Content-Type: application/json' \
            --data-binary @-
  )"

  # Optional debug
  if [[ "${DEBUG_ARIA2:-0}" == "1" ]]; then
    echo "---- addUri request ----" >&2;  echo "$req"  | jq . >&2
    echo "---- addUri response ----" >&2; echo "$resp" | jq . >&2 || echo "$resp" >&2
  fi

  gid="$(jq -r 'select(.result) | .result' <<<"$resp" 2>/dev/null || true)"
  err="$(jq -r 'select(.error)  | .error.message' <<<"$resp" 2>/dev/null || true)"

  if [[ -n "$gid" && "$gid" != "null" ]]; then
    echo "$gid"
    return 0
  fi

  echo "❌ aria2.addUri failed for: $out" >&2
  echo "    URL: $url" >&2
  if [[ -n "$err" && "$err" != "null" ]]; then
    echo "    Error: $err" >&2
  else
    echo "    Raw response: $resp" >&2
  fi
  return 1
}
