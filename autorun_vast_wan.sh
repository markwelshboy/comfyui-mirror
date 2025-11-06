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
  git git-lfs curl ca-certificates unzip \
  ffmpeg libgl1 libglib2.0-0 \
  aria2 jq gawk nano coreutils \
  tmux net-tools ncurses-base bash-completion
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

# ------------- DEFAULT_NODES in .env

# 1) Compute pins once (helpers read $PY inside pins_signature)
export PINS="$(pins_signature)"
echo "[custom-nodes] PINS = $PINS"

# 2) Prefer HF bundle for (BUNDLE_TAG + PINS); else build from list (CUSTOM_NODE_LIST_FILE → CUSTOM_NODE_LIST → DEFAULT_NODES)
ensure_nodes_from_bundle_or_build

# 3) Optional: push a new bundle if requested (requires HF_* env set)
push_bundle_if_requested

# =============================================================================================
#
#
#  6 ) Download all requested models, from HuggingFace manifests, CivitAI, etc.
#
#
# =============================================================================================

echo "Ensuring model directories exist..."
mkdir -p "$DIFFUSION_MODELS_DIR" "$TEXT_ENCODERS_DIR" "$CLIP_VISION_DIR" "$VAE_DIR" \
  "$LORAS_DIR" "$DETECTION_DIR" "$CTRL_DIR" "$UPSCALE_DIR"

#===============================================================================================
#  6.1) Huggingface Model downloader from manifest (uses helpers.sh)
#===============================================================================================

aria2_enqueue_and_wait_from_manifest

echo "✅ All Huggingface models from manifest downloaded."

#===============================================================================================
#  6.2) CivitAI model downloader
#===============================================================================================

#----------- Download CivitAI downloader script ----------
#echo "Downloading CivitAI download script to /usr/local/bin"
#git clone "https://github.com/Hearmeman24/CivitAI_Downloader.git" || { echo "Git clone failed"; exit 1; }
#mv CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || { echo "Move failed"; exit 1; }
#chmod +x "/usr/local/bin/download_with_aria.py" || { echo "Chmod failed"; exit 1; }
#rm -rf CivitAI_Downloader  # Clean up the cloned repo

#mkdir -p "${CIVITAI_LOG_DIR}"
#echo "Downloading models from CivitAI..."

# Using env-defined lists (checkpoints + loras):
#download_civitai_ids

# Optional: wait until aria2 RPC daemon is idle
#echo "⏳ Waiting for background aria2 downloads to finish..."
#while pgrep -x "aria2c" >/dev/null; do
#  echo "🔽 Downloads still running..."
#  sleep 5
#done

echo "Downloading CivitAI assets using environment-defined lists..."

aria2_enqueue_and_wait_from_civitai

echo "✅ All CivitAI models downloaded successfully!"

#===============================================================================================
#  6.2.1) Rename any .zip loras to .safetensors
#===============================================================================================
#echo "Renaming loras downloaded as zip files to safetensors files...."
#cd $LORAS_DIR
#for file in *.zip; do
#  echo "Renaming $file to ${file%.zip}.safetensors"
#  mv "$file" "${file%.zip}.safetensors"
#done
# Return to workspace
#cd /workspace

#===============================================================================================
#  6.3) Relocate upscaling models from comfyui-mirror git dir to proper upscale dir
#===============================================================================================

echo "Relocate upscaling model(s) to the correct directory..."
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

#===============================================================================================
#  6.4) Copy Hearmeman24's WAN workflows into ComfyUI workflows dir
#===============================================================================================

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

#===============================================================================================
#  6.5) Change default preview method to 'auto' in VHS Latent Preview node
#===============================================================================================

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
  else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
  fi
  
  echo "Config file setup complete!"
  echo "Default preview method updated to 'auto'"

else
  echo "Skipping preview method update (change_preview_method is not 'true')."
fi

#===============================================================================================
#
#  7 ) Launch ComfyUI instances (8188 main, 8288 GPU0, 8388 GPU1)
#
#===============================================================================================

echo "▶️  Starting ComfyUI"

if ${SCRIPT_DIR}/run_comfy_mux.sh; then
  tg "✅ ComfyUI up on 8188, 8288 (GPU0), 8388 (GPU1 if present)."
else
  tg "⚠️ ComfyUI launch had warnings. Check ${COMFY_LOGS}."
fi

echo "Bootstrap complete. General Comfy Logs: ${COMFY_LOGS} | Bootstrap log: ${LOGFILE_BOOTSTRAP}"
sleep infinity
