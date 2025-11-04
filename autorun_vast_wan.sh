#!/usr/bin/env bash
set -euo pipefail

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
DIFF="$COMFY/models/diffusion_models"
TEXT="$COMFY/models/text_encoders"
CLIPV="$COMFY/models/clip_vision"
VAE="$COMFY/models/vae"
LORA="$COMFY/models/loras"
DET="$COMFY/models/detection"
CTRL="$COMFY/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
mkdir -p "$DIFF" "$TEXT" "$CLIPV" "$VAE" "$LORA" "$DET" "$CTRL" "$COMFY/models/upscale_models"

# Example: enable with env download_wan22=true (in Vast GUI)
if [ "${download_wan22:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors"   "$DIFF/wan2.2_t2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"    "$DIFF/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors"   "$DIFF/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"    "$DIFF/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors"              "$DIFF/wan2.2_ti2v_5B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors"                                    "$VAE/wan2.2_vae.safetensors"
fi

echo "Downloading upscale models"
mkdir -p "$COMFY/models/upscale_models"
if [ ! -f "$COMFY/models/upscale_models/4xLSDIR.pth" ]; then
    if [ -f "$COMFY/comfyui-mirror/4xLSDIR.pth" ]; then
        mv "$COMFY/comfyui-mirror/4xLSDIR.pth" "$COMFY/models/upscale_models/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the root directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

# ---------- 7) Final launch script ----------

if ${SCRIPT_DIR}/run_comfy_mux.sh; then
  tg "✅ ComfyUI up on 8188, 8288 (GPU0), 8388 (GPU1 if present)."
else
  tg "⚠️ ComfyUI launch had warnings. Check /workspace/logs/."
fi

echo "Bootstrap complete. Logs: ${COMFY_LOGS}  |  Bootstrap: ${LOGFILE_BOOTSTRAP}"
sleep infinity
