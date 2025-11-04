#!/usr/bin/env bash
set -euo pipefail

touch ~/.no_auto_tmux

# -----------------------------
# -1) Special overrides
# -----------------------------

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "/workspace/additional_params.sh" ]; then
    chmod +x /workspace/additional_params.sh
    echo "Executing additional_params.sh..."
    /workspace/additional_params.sh
else
    echo "additional_params.sh not found in /workspace. Skipping..."
fi

# -----------------------------
# 0) OS prereqs & workspace
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
umask 0022
mkdir -p /workspace
apt-get update
apt-get install -y --no-install-recommends \
  python3.12 python3.12-venv python3.12-dev python3-pip \
  build-essential ninja-build pkg-config cmake gcc g++ \
  git git-lfs curl ca-certificates \
  ffmpeg libgl1 libglib2.0-0
git lfs install --system || true

# -----------------------------
# 1) Ensure venv exists FIRST
# -----------------------------
if [ ! -x /opt/venv/bin/python ]; then
  python3.12 -m venv /opt/venv
fi

# -----------------------------
# 2) Require .env and helpers
#    (.env defines PATH, PY, PIP, pip flags, etc.)
# -----------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${ENVIRONMENT:-$SCRIPT_DIR/.env}"
HELPERS="${HELPERS:-$SCRIPT_DIR/helpers.sh}"

if [ ! -f "$ENVIRONMENT" ]; then
  echo "[fatal] Required .env not found at: $ENVIRONMENT"
  echo "        Create it (see sample below) and re-run."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENVIRONMENT"

if [ ! -f "$HELPERS" ]; then
  echo "[fatal] helpers.sh not found at: $HELPERS"
  exit 1
fi
# shellcheck source=/dev/null
source "$HELPERS"

# -----------------------------
# 3) Sanity checks from .env
# -----------------------------
: "${PY:?PY must be set by .env}"
: "${PIP:?PIP must be set by .env}"

if [ ! -x "$PY" ] || [ ! -x "$PIP" ]; then
  echo "[fatal] PY or PIP path invalid:"
  echo "  PY : $PY"
  echo "  PIP: $PIP"
  exit 1
fi

# ==============================================================================================
#  Main entrypoint logic
# ==============================================================================================

# =========================
#  Directories
# =========================
ensure_dirs

# Base tooling in venv
$PIP install -U pip wheel setuptools ninja packaging

# ---------- torch first (CUDA 12.8 nightly channel) ----------
( PIP_CONSTRAINT=""; $PIP install --pre torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/nightly/cu128 )
$PY - <<'PY'
import torch; print("torch:", torch.__version__)
PY

# ---------- GPU arch detect + SageAttention build (arch-aware) ----------
# Pre-reqs (Python.h, nvcc toolchain, ninja) should already be installed earlier.
GPU_CC="$($PY - <<'PY'
import torch, json
if not torch.cuda.is_available():
    print("0.0"); raise SystemExit
d= torch.cuda.get_device_capability(0)  # (major, minor)
print(f"{d[0]}.{d[1]}")
PY
)"

echo "Detected GPU compute capability: ${GPU_CC}"

# Map CC → sensible arch lists
case "$GPU_CC" in
  9.0)  # Hopper (H100)
    export TORCH_CUDA_ARCH_LIST="9.0;8.9;8.6;8.0"
    SAGE_GENCODE="-gencode arch=compute_90,code=sm_90"
    # Try newer first (main), then the Ada commit as fallback
    SAGE_COMMITS=("main" "68de379")
    ;;
  8.9)  # Ada (L40S, RTX 6000 Ada)
    export TORCH_CUDA_ARCH_LIST="8.9;8.6;8.0"
    SAGE_GENCODE="-gencode arch=compute_89,code=sm_89"
    SAGE_COMMITS=("68de379" "main")
    ;;
  8.*)  # Ampere (A100=8.0, 3090=8.6, etc.)
    export TORCH_CUDA_ARCH_LIST="8.6;8.0"
    SAGE_GENCODE="-gencode arch=compute_86,code=sm_86 -gencode arch=compute_80,code=sm_80"
    SAGE_COMMITS=("main" "68de379")
    ;;
  *)    # Fallback
    export TORCH_CUDA_ARCH_LIST="8.0"
    SAGE_GENCODE="-gencode arch=compute_80,code=sm_80"
    SAGE_COMMITS=("main" "68de379")
    ;;
esac

echo "TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}"
echo "NVCC extra: ${SAGE_GENCODE}"

# Build SageAttention (sequential, with fallbacks)
echo "Building SageAttention..."
rm -rf /tmp/SageAttention
git clone https://github.com/thu-ml/SageAttention.git /tmp/SageAttention

SAGE_OK=0
for c in "${SAGE_COMMITS[@]}"; do
  if build_sage "$c" 2>&1 | tee /workspace/logs/sage_build_${c}.log; then
    echo "SageAttention built successfully at commit ${c}"
    SAGE_OK=1
    break
  else
    echo "SageAttention build failed at commit ${c} — will try next (if any)…"
  fi
done

if [ "$SAGE_OK" -ne 1 ]; then
  echo "FATAL: SageAttention failed to build for CC=${GPU_CC}. See logs in /workspace/logs/sage_build_*.log"
  # You can choose to exit 1 here, or continue without --use-sage-attention
  # exit 1
fi

# ---------- OpenCV cleanup (avoid 'cv2' namespace collisions) ----------
$PIP uninstall -y opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless >/dev/null 2>&1 || true
$PY - <<'PY'
import sys, os, glob, shutil
site=[p for p in sys.path if p.endswith("site-packages")]
if site:
    site=site[0]
    for p in [os.path.join(site,"cv2"), *glob.glob(os.path.join(site,"cv2*"))]:
        try:
            if os.path.isdir(p): shutil.rmtree(p, ignore_errors=True)
            elif os.path.isfile(p): os.remove(p)
            print("Removed:", p)
        except Exception as e:
            print("Skip:", p, e)
PY

# ---------- pin numeric stack (single source of truth) ----------

$PIP install -U numpy cupy-cuda12x opencv-contrib-python
$PY - <<'PY'
import numpy, importlib
print("numpy:", numpy.__version__)
try:
    import cupy; print("cupy:", cupy.__version__)
except Exception as e:
    print("cupy ERROR:", e)
try:
    import cv2
    v=getattr(cv2,"__version__",None)
    if v is None:
        cv2=cv2.cv2
        v=cv2.__version__
    print("opencv:", v)
except Exception as e:
    print("opencv ERROR:", e)
PY

#====================================================================================
# Ensure ComfyUI present and up-to-date
#
#====================================================================================

ensure_comfy

# =============================================================================================
#  Hearmeman WAN templates/other (special case)
# =============================================================================================

copy_hearmeman_assets_if_any

# =============================================================================================
#  Custom nodes management
# =============================================================================================

# 0) Prepare dirs
mkdir -p "$COMFY_LOGS" "$OUTPUT_DIR" "$CACHE_DIR" "$BUNDLES_DIR" "$CUSTOM_DIR" "$CUSTOM_LOG_DIR"

# 0.5) Try to fetch remote node list (optional). If HF isn't configured, this will no-op.
#      If we get a list, write it to a temp file and let the installer use it.
REMOTE_LIST="$(hf_fetch_nodes_list || true)"
if [[ -n "$REMOTE_LIST" ]]; then
  NODES_TMP_FILE="$(mktemp -p "${CACHE_DIR:-/tmp}" custom_nodes_list.XXXXXX)"
  printf '%s\n' "$REMOTE_LIST" | grep -vE '^\s*(#|$)' > "$NODES_TMP_FILE"
  export CUSTOM_NODE_LIST_FILE="$NODES_TMP_FILE"
  echo "[custom-nodes] Using nodes list from HF: $CUSTOM_NODE_LIST_FILE"
else
  echo "[custom-nodes] No remote nodes list found on HF; will use local CUSTOM_NODE_LIST or DEFAULT_NODES."
fi

# -- Default/fallback nodes (must be exported before helpers that resolve lists)
export DEFAULT_NODES=(
  https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git
  https://github.com/kijai/ComfyUI-KJNodes.git
  https://github.com/rgthree/rgthree-comfy.git
  https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git
  https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git
  https://github.com/Jordach/comfy-plasma.git
  https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
  https://github.com/bash-j/mikey_nodes.git
  https://github.com/ltdrdata/ComfyUI-Impact-Pack.git
  https://github.com/Fannovel16/comfyui_controlnet_aux.git
  https://github.com/yolain/ComfyUI-Easy-Use.git
  https://github.com/kijai/ComfyUI-Florence2.git
  https://github.com/ShmuelRonen/ComfyUI-LatentSyncWrapper.git
  https://github.com/WASasquatch/was-node-suite-comfyui.git
  https://github.com/theUpsider/ComfyUI-Logic.git
  https://github.com/cubiq/ComfyUI_essentials.git
  https://github.com/chrisgoringe/cg-image-picker.git
  https://github.com/chflame163/ComfyUI_LayerStyle.git
  https://github.com/chrisgoringe/cg-use-everywhere.git
  https://github.com/kijai/ComfyUI-segment-anything-2.git
  https://github.com/ClownsharkBatwing/RES4LYF
  https://github.com/welltop-cn/ComfyUI-TeaCache.git
  https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git
  https://github.com/Jonseed/ComfyUI-Detail-Daemon.git
  https://github.com/kijai/ComfyUI-WanVideoWrapper.git
  https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git
  https://github.com/BadCafeCode/masquerade-nodes-comfyui.git
  https://github.com/1038lab/ComfyUI-RMBG.git
  https://github.com/M1kep/ComfyLiterals.git
  https://github.com/wildminder/ComfyUI-VibeVoice.git
  https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git
)

# 1) Compute pins once (helpers read $PY inside pins_signature)
export PINS="$(pins_signature)"
echo "[custom-nodes] PINS = $PINS"

# 2) Prefer HF bundle for (BUNDLE_TAG + PINS); else build from list (CUSTOM_NODE_LIST_FILE → CUSTOM_NODE_LIST → DEFAULT_NODES)
ensure_nodes_from_bundle_or_build

# 3) Optional: push a new bundle if requested (requires HF_* env set)
push_bundle_if_requested

# 4) Cleanup temp list
[[ -n "${NODES_TMP_FILE:-}" && -f "$NODES_TMP_FILE" ]] && rm -f "$NODES_TMP_FILE" || true

# ---------- 5) VHS preview default (optional) ----------
if [ "${change_preview_method:-true}" = "true" ]; then
  JS="$CUSTOM_DIR/ComfyUI-VideoHelperSuite/web/js/VHS.core.js"
  [ -f "$JS" ] && sed -i "/id: *'VHS.LatentPreview'/,/defaultValue:/s/defaultValue: false/defaultValue: true/" "$JS" || true
  mkdir -p "$COMFY_HOME/user/default/ComfyUI-Manager"
  CFG="$COMFY_HOME/user/default/ComfyUI-Manager/config.ini"
  if [ ! -f "$CFG" ]; then
    cat >"$CFG" <<'INI'
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
INI
  fi
fi

# ---------- 6) Model directories + simple downloader ----------

# Define base paths
DIFFUSION_MODELS_DIR="$COMFY/models/diffusion_models"
TEXT_ENCODERS_DIR="$COMFY/models/text_encoders"
CLIP_VISION_DIR="$COMFY/models/clip_vision"
VAE_DIR="$COMFY/models/vae"
LORAS_DIR="$COMFY/models/loras"
DETECTION_DIR="$COMFY/models/detection"
CTRL_DIR="$COMFY/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
UPSCALE_DIR="$COMFY/models/upscale_models"
mkdir -p "$DIFFUSION_MODELS_DIR" "$TEXT_ENCODERS_DIR" "$CLIP_VISION_DIR" "$VAE_DIR" \
  "$LORAS_DIR" "$DETECTION_DIR" "$CTRL_DIR" "$UPSCALE_DIR"

# 6.1) CivitAI downloader script

echo "Downloading CivitAI download script to /usr/local/bin"
git clone "https://github.com/Hearmeman24/CivitAI_Downloader.git" || { echo "Git clone failed"; exit 1; }
mv CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || { echo "Move failed"; exit 1; }
chmod +x "/usr/local/bin/download_with_aria.py" || { echo "Chmod failed"; exit 1; }
rm -rf CivitAI_Downloader  # Clean up the cloned repo

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

echo "✅ All models downloaded successfully!"

echo "Relocate upscale models"
if [ ! -f "$UPSCALE_DIR/4xLSDIR.pth" ]; then
    if [ -f "/workspace/comfyui-mirror/4xLSDIR.pth" ]; then
        mv "/workspace/comfyui-mirror/4xLSDIR.pth" "$UPSCALE_DIR/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the comfyui-mirror git directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

echo "✅ All requested downloads completed!"

#----------- 6.5) Fetch/Move workflow files ----------

echo "Cloning Hearmeman24's ComfyUI-WAN repository for latest workflows..."
cd /workspace
if [ -d comfyui-wan/.git ]; then
  (cd comfyui-wan && git pull --rebase --autostash || true)
else
  git clone https://github.com/Hearmeman24/comfyui-wan.git
fi
cd comfyui-wan

# Ensure the file exists in the current directory before moving it
SOURCE_DIR="/workspace/comfyui-wan/workflows"

# Ensure destination directory exists
mkdir -p "$WORKFLOW_DIR"

# Loop over each subdirectory in the source directory
for dir in "$SOURCE_DIR"/*/; do
    # Skip if no directories match (empty glob)
    [[ -d "$dir" ]] || continue

    dir_name="$(basename "$dir")"
    dest_dir="$WORKFLOW_DIR/$dir_name"

    if [[ -e "$dest_dir" ]]; then
        echo "Directory already exists in destination. Deleting source: $dir"
        rm -rf "$dir"
    else
        echo "Moving: $dir to $WORKFLOW_DIR"
        mv "$dir" "$WORKFLOW_DIR/"
    fi
done

# ---------- 7) Final launch script ----------

if ${SCRIPT_DIR}/run_comfy_mux.sh; then
  tg "✅ ComfyUI up on 8188, 8288 (GPU0), 8388 (GPU1 if present)."
else
  tg "⚠️ ComfyUI launch had warnings. Check ${COMFY_LOGS}."
fi

echo "Bootstrap complete. General Comfy Logs: ${COMFY_LOGS} | Bootstrap log: ${LOGFILE_BOOTSTRAP}"
sleep infinity
