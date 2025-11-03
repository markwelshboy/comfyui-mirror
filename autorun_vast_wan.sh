#!/usr/bin/env bash
set -euo pipefail

touch /root/.no_auto_tmux

mkdir -p /workspace

# =========================
#  Hugging Face helpers
# =========================
export HF_REPO_ID="${HF_REPO_ID:-markwelshboyx/comfyui-bundles}"
export CN_BRANCH="${CN_BRANCH:-main}"
export HF_API_BASE="https://huggingface.co"
export HF_AUTH_HEADER="Authorization: Bearer ${HF_TOKEN:-}"

#  Git repo URL for ComfyUI
REPO_URL="https://github.com/comfyanonymous/ComfyUI"

# =========================
#  COMFY config helpers
# =========================
export COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"
export COMFY=$COMFY_HOME
export COMFYUI_PATH=$COMFY_HOME

# =========================
#  For custom_nodes management
# =========================

CUSTOM_DIR="${CUSTOM_DIR:-$COMFY_HOME/custom_nodes}"
CUSTOM_LOG_DIR="${CUSTOM_LOG_DIR:-/workspace/logs/custom_nodes}"
MAX_NODE_JOBS="${MAX_NODE_JOBS:-8}"         # parallelism cap
PIP_EXTRA_OPTS="${PIP_EXTRA_OPTS:-}"        # e.g. "--constraint /workspace/pins.txt"
GIT_DEPTH="${GIT_DEPTH:-1}"                 # 0 means full; 1 is shallow

mkdir -p $CUSTOM_DIR $CUSTOM_LOG_DIR

# Ensure git-lfs etc are present
need_tools_for_hf() {
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq git git-lfs >/dev/null 2>&1 || true
  git lfs install --system || true
}

# Build a pin signature from the currently active venv
pins_signature() {
  "$PY" - <<'PY'
import importlib, re, sys
def v(mod, attr="__version__"):
    try:
        m = importlib.import_module(mod)
        return getattr(m, attr, "0.0.0")
    except Exception:
        return "0.0.0"

np = v("numpy")
try:
    cv = importlib.import_module("cv2")
    cvv = getattr(cv, "__version__", None)
    if not cvv or cvv == cv:  # namespace pkg case
        raise Exception()
    cv = cvv
except Exception:
    cv = "0.0.0"

cp = v("cupy")
# normalize: replace non [0-9.] with '-' and dots with 'd'
def norm(s): return re.sub(r'[^0-9\.]+','-',s).replace('.','d')
sig = f"np{norm(np)}_cupy{norm(cp)}_cv{norm(cv)}"
print(sig)
PY
}

# Resolve list of available files in the repo (JSON) and pick newest matching pins
hf_latest_bundle_for_pins() {
  local PINS="$1"
  local url="$HF_API_BASE/api/models/$HF_REPO_ID/tree/$CN_BRANCH?recursive=1"
  local json="$(curl -fsSL -H "$HF_AUTH_HEADER" "$url" || true)"
  [ -n "$json" ] || { echo ""; return 0; }
  echo "$json" \
    | jq -r --arg PINS "$PINS" '
      [ .[] 
        | select(.type=="file") 
        | select(.path|test("^bundles/custom_nodes_bundle_\\Q"+$PINS+"\\E_\\d{8}-\\d{4}\\.tgz$"))
        | .path ] 
      | sort 
      | last // "" '
}

# Download a file from HF to local dest
hf_download_to() {
  local REPO_PATH="$1"   # e.g. bundles/custom_nodes_bundle_np2d2d6_cupy13d6d0_cv4d12d0d88_20251103-0943.tgz
  local DEST="$2"
  local url="$HF_API_BASE/$HF_REPO_ID/resolve/$CN_BRANCH/$REPO_PATH"
  aria2c -x16 -s16 -k1M -o "$(basename "$DEST")" -d "$(dirname "$DEST")" "$url"
}

# Upload (commit) files to HF repo using git+LFS
hf_push_files() {
  local TMP="/workspace/.hf_push.$$"
  local MSG="${1:-"update bundles"}"; shift || true
  local FILES=( "$@" )

  need_tools_for_hf
  rm -rf "$TMP"
  GIT_ASKPASS=/bin/echo git clone "https://oauth2:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}" "$TMP"
  cd "$TMP"
  git checkout "$CN_BRANCH" 2>/dev/null || git checkout -b "$CN_BRANCH"
  mkdir -p bundles
  for f in "${FILES[@]}"; do
    cp -f "$f" bundles/
  done
  git add bundles
  git commit -m "$MSG" || true
  git push origin "$CN_BRANCH"
}

# Pull a custom_nodes.txt (list of repos) if present; echo the path or empty
hf_fetch_nodes_list() {
  local OUT="/workspace/cache/custom_nodes.txt"
  mkdir -p /workspace/cache
  local url="$HF_API_BASE/$HF_REPO_ID/resolve/$CN_BRANCH/custom_nodes.txt"
  if curl -fsSL -H "$HF_AUTH_HEADER" "$url" -o "$OUT"; then
    echo "$OUT"
  else
    echo ""
  fi
}

# =========================
#  Bundling helpers
# =========================
# Create manifest + consolidated requirements (skips heavy pins we manage)
make_nodes_manifest_and_reqs() {
  local CN="$CUST"
  local OUTDIR="$1"
  mkdir -p "$OUTDIR"

  # manifest of repo URLs + commit SHAs
  "$PY" - <<PY > "$OUTDIR/custom_nodes_manifest.json"
import os, subprocess, json, glob
cn = os.environ.get("CUST")
pins={}
for g in glob.glob(os.path.join(cn, "*/.git")):
    repo = os.path.basename(os.path.dirname(g))
    try:
        sha = subprocess.check_output(["git","-C",os.path.dirname(g),"rev-parse","HEAD"], text=True).strip()
        url = subprocess.check_output(["git","-C",os.path.dirname(g),"config","--get","remote.origin.url"], text=True).strip()
        pins[repo]={"commit":sha,"origin":url}
    except Exception: pass
print(json.dumps(pins, indent=2))
PY

  # consolidate requirements
  local REQ_ALL="$OUTDIR/_all_requirements.txt"
  : > "$REQ_ALL"
  find "$CN" -maxdepth 2 -type f -name requirements.txt -print0 \
    | xargs -0 -I{} bash -lc "cat '{}' >> '$REQ_ALL'" || true

  # strip heavy/conflicting libs we pin elsewhere
  grep -vE '^(torch|torchvision|torchaudio|opencv(|-python|-contrib-python|-headless)|cupy(|-cuda.*)|numpy)\b' "$REQ_ALL" \
    | sed '/^\s*#/d;/^\s*$/d' \
    | sort -u > "$OUTDIR/consolidated_requirements.txt"
  rm -f "$REQ_ALL"
}

# Tar up custom_nodes with a pin-aware name; print full path to tar
build_custom_nodes_bundle() {
  local PINS="$1"
  local TAG="$(date +%Y%m%d-%H%M)"
  local OUTBASE="/workspace/cache/custom_nodes_bundle_${PINS}_${TAG}"
  mkdir -p /workspace/cache
  make_nodes_manifest_and_reqs "/workspace/cache"
  tar --owner=0 --group=0 --numeric-owner -C "$CUST" -czf "${OUTBASE}.tgz" .
  sha256sum "${OUTBASE}.tgz" > "${OUTBASE}.tgz.sha256"
  echo "${OUTBASE}.tgz"
}

# Extract a bundle into custom_nodes (overlay)
extract_custom_nodes_bundle() {
  local TARBALL="$1"
  mkdir -p "$CUST"
  tar -xzf "$TARBALL" -C "$CUST"
}

# Install consolidated requirements (safe with your pins)
safe_install_consolidated_reqs() {
  local REQS="/workspace/cache/consolidated_requirements.txt"
  [ -f "$REQS" ] || return 0
  $PIP install --no-cache-dir -r "$REQS" || true
}

# ---------- helper: safe requirements install (keeps pins intact) ----------
safe_pip_install_reqs() {
  local req="$1"
  # Try normal install; tolerate failures and re-pin afterwards to avoid drift
  $PIP install -r "$req" || true
  $PIP install -U "numpy>=2.0,<2.3" "cupy-cuda12x>=13.0.0" "opencv-contrib-python==4.12.0.88"
}

# --- Helper: safe repo name (dir) ---
repo_dir_name() {
  # Strip trailing .git, take basename
  local u="$1"
  basename "${u%.git}"
}

# --- Helper: clone or pull (supports recursive for specific repos) ---
clone_or_pull() {
  local repo="$1"
  local dst="$2"
  local recursive="$3" # "true" or "false"
  if [[ -d "$dst/.git" ]]; then
    git -C "$dst" fetch --all --prune --tags --depth="$GIT_DEPTH" || true
    # Prefer main/master reset
    git -C "$dst" reset --hard origin/main 2>/dev/null || \
    git -C "$dst" reset --hard origin/master 2>/dev/null || true
  else
    if [[ "$recursive" == "true" ]]; then
      git -C "$CUSTOM_DIR" clone --recursive ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    else
      git -C "$CUSTOM_DIR" clone ${GIT_DEPTH:+--depth "$GIT_DEPTH"} "$repo" "$dst"
    fi
  fi
}

# --- Helper: per-node build/install (requirements.txt then install.py) ---
build_node() {
  local dst="$1"
  local name
  name="$(basename "$dst")"
  local log="$CUSTOM_LOG_DIR/${name}.log"

  {
    echo "==> [$name] starting at $(date -Is)"
    if [[ -f "$dst/requirements.txt" ]]; then
      echo "==> [$name] pip install -r requirements.txt"
      $PIP install --no-cache-dir $PIP_EXTRA_OPTS -r "$dst/requirements.txt"
    fi
    if [[ -f "$dst/install.py" ]]; then
      echo "==> [$name] python install.py"
      "$PY" "$dst/install.py"
    fi
    echo "==> [$name] done at $(date -Is)"
  } >"$log" 2>&1
}

# --- Nodes that require recursive clone (submodules) ---
needs_recursive() {
  case "$1" in
    *ComfyUI_UltimateSDUpscale*) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ---------- Helper to install nodes ----------
install_node () {
  local repo="$1"
  local dest="$CUST/$(basename "$repo" .git)"
  if [ ! -d "$dest/.git" ]; then
    if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then
      git -C "$CUST" clone --recursive "$repo"
    else
      git -C "$CUST" clone "$repo"
    fi
  else
    git -C "$dest" pull --rebase || true
  fi
  [ -f "$dest/requirements.txt" ] && safe_pip_install_reqs "$dest/requirements.txt" || true
  [ -f "$dest/install.py" ]       && $PY  "$dest/install.py" || true
}


# ==============================================================================================
# System prerequisites (must be before any torch/extension builds)
# ==============================================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  python3.12-dev build-essential ninja-build git curl ca-certificates

# ==============================================================================================
#  Main entrypoint logic
# ==============================================================================================

# --- venv & PATH ---
if [ ! -x /opt/venv/bin/python ]; then
  python3.12 -m venv /opt/venv
fi
export PATH="/opt/venv/bin:$PATH"
PY="/opt/venv/bin/python"
PIP="$PY -m pip"

# Keep pip predictable
export PIP_NO_INPUT=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

# Base tooling in venv
$PIP install -U pip wheel setuptools ninja packaging

# ---------- torch first (CUDA 12.8 nightly channel) ----------
$PIP install --pre torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/nightly/cu128
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

build_sage() {
  local commit="$1"
  echo "  -> trying commit: $commit"
  ( set -e
    cd /tmp/SageAttention
    git fetch --all --tags
    git reset --hard "$commit"

    # Environment to help nvcc/torch extensions:
    export MAX_JOBS="${MAX_JOBS:-32}"
    export EXT_PARALLEL="${EXT_PARALLEL:-4}"
    export NVCC_APPEND_FLAGS="--threads 8"
    export FORCE_CUDA=1
    export CXX="${CXX:-g++}"
    export CC="${CC:-gcc}"

    # Feed explicit gencode flags via env Torch respects:
    export EXTRA_NVCCFLAGS="${SAGE_GENCODE}"

    # No isolation so it sees torch headers in the venv
    $PIP install --no-build-isolation -e . 
  )
}

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
cat >/workspace/pins.txt <<'PIN'
numpy>=2.2,<2.3
cupy-cuda12x>=13.6.0
opencv-contrib-python==4.12.0.88
PIN
export PIP_EXTRA_OPTS="--constraint /workspace/pins.txt"

$PIP install $PIP_EXTRA_OPTS -U numpy cupy-cuda12x opencv-contrib-python
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

ensure_comfy() {
  # If it looks like a valid git checkout, hard-reset it
  if [ -d "$COMFY_HOME/.git" ] && [ -f "$COMFY_HOME/main.py" ]; then
    git -C "$COMFY_HOME" fetch --depth=1 origin
    git -C "$COMFY_HOME" reset --hard origin/master || git -C "$COMFY_HOME" reset --hard origin/main || true
  else
    # Anything else (empty/invalid dir) → replace cleanly
    rm -rf "$COMFY_HOME"
    git clone --depth=1 "$REPO_URL" "$COMFY_HOME"
  fi

  # deps (safe to re-run)
  $PIP install -U pip wheel setuptools
  [ -f "$COMFY_HOME/requirements.txt" ] && $PIP install -r "$COMFY_HOME/requirements.txt" || true

  # keep /ComfyUI pointing to the workspace copy
  ln -sfn "$COMFY_HOME" /ComfyUI
}

# Build Comfy

ensure_comfy

# 3) Ensure tools available for HF downloads
need_tools_for_hf

mkdir -p /workspace/logs "$COMFY/output" "$COMFY/cache" "$CUSTOM_DIR" "$CUSTOM_LOG_DIR"

# ---------- 4) Node set ----------
DEFAULT_NODES=(
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
# --- Source of truth for nodes ---
# 1) CUSTOM_NODE_LIST_FILE (one repo per line)
# 2) CUSTOM_NODE_LIST (space/newline separated)
# 3) DEFAULT_NODES
NODES=()
if [[ -n "${CUSTOM_NODE_LIST_FILE:-}" && -f "${CUSTOM_NODE_LIST_FILE:-}" ]]; then
  mapfile -t NODES < <(grep -vE '^\s*(#|$)' "$CUSTOM_NODE_LIST_FILE")
elif [[ -n "${CUSTOM_NODE_LIST:-}" ]]; then
  # shellcheck disable=SC2206
  NODES=(${CUSTOM_NODE_LIST})
else
  NODES=("${DEFAULT_NODES[@]}")
fi

# --- Simple semaphore using a named pipe (portable, no GNU parallel needed) ---
SEM_FIFO="/tmp/.nodes.sem.$$"
mkfifo "$SEM_FIFO"
exec 9<>"$SEM_FIFO"
rm -f "$SEM_FIFO"
# pre-fill tokens
for _ in $(seq 1 "$MAX_NODE_JOBS"); do echo >&9; done

# --- Main loop: clone/update + build in parallel, with bounded concurrency ---
pids=()
errs=0
for repo in "${NODES[@]}"; do
  # sanitize blank/comment
  [[ -n "$repo" ]] || continue
  [[ "$repo" =~ ^# ]] && continue

  read -r _ <&9  # acquire token

  (
    name="$(repo_dir_name "$repo")"
    dst="$CUSTOM_DIR/$name"
    rec="$(needs_recursive "$repo")"

    echo "[custom-nodes] $name → $dst"
    mkdir -p "$dst"
    clone_or_pull "$repo" "$dst" "$rec"

    # Per-node installation (requirements/install.py)
    if ! build_node "$dst"; then
      echo "[custom-nodes] ERROR building $name (see $CUSTOM_LOG_DIR/${name}.log)"
      exit 1
    fi
    echo "[custom-nodes] OK $name"
  ) &
  pid=$!
  pids+=("$pid")

  # release token when job ends
  {
    wait "$pid" || errs=$((errs+1))
    echo >&9
  } &
done

# Wait for all release-waiters
echo "[custom-nodes] Waiting for parallel node installs to complete..."
wait

# Final status
if (( errs > 0 )); then
  echo "[custom-nodes] Completed with $errs error(s). Check logs in: $LOG_DIR"
  exit 2
else
  echo "[custom-nodes] All nodes installed successfully."
fi

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
mkdir -p "$DIFF" "$TEXT" "$CLIPV" "$VAE" "$LORA" "$DET" "$CTRL" "$COMFY/models/upscale_models" /workspace/logs

dl() { aria2c -x16 -s16 -k1M --continue=true -d "$(dirname "$2")" -o "$(basename "$2")" "$1"; }

# Example: enable with env download_wan22=true (in Vast GUI)
if [ "${download_wan22:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "$DIFF/wan2.2_t2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"  "$DIFF/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors"   "$DIFF/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"    "$DIFF/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors"              "$DIFF/wan2.2_ti2v_5B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors"                                    "$VAE/wan2.2_vae.safetensors"
fi

# Telegram notify helper
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

cat >/workspace/run_comfy_mux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/venv/bin:$PATH"
BASE=/ComfyUI
LOGS=/workspace/logs
mkdir -p "$LOGS" "$BASE/output" "$BASE/cache"

/usr/bin/printf "GPUs: "
python - <<'PY'
import torch; print(torch.cuda.device_count() if torch.cuda.is_available() else 0)
PY

health() {
  local name=$1 port=$2
  local t=0
  until curl -fsS "http://127.0.0.1:${port}" >/dev/null 2>&1; do
    sleep 2; t=$((t+2))
    [ $t -ge 60 ] && echo "WARN: ${name} on ${port} not 200 after 60s." && exit 1
  done
  echo "OK: ${name} is UP on :${port}"
}

start_one() {
  local sess=$1 port=$2 gvar=$3 out=$4 cache=$5
  tmux new-session -d -s "$sess" \
    "CUDA_VISIBLE_DEVICES=${gvar} PYTHONUNBUFFERED=1 \
     python ${BASE}/main.py --listen --port ${port} --use-sage-attention \
       --output-directory ${out} --temp-directory ${cache} \
       >> ${LOGS}/comfyui-${port}.log 2>&1"
  ( health "$sess" "$port" ) || true
}

tmux new-session -d -s comfy-8188 \
  "PYTHONUNBUFFERED=1 python ${BASE}/main.py --listen --port 8188 --use-sage-attention \
   --output-directory ${BASE}/output --temp-directory ${BASE}/cache \
   >> ${LOGS}/comfyui-8188.log 2>&1"
( health "comfy-8188" 8188 ) || true

gpus=$(python - <<'PY'
import torch
print(torch.cuda.device_count() if torch.cuda.is_available() else 0)
PY
)
if [ "$gpus" -ge 1 ]; then
  mkdir -p /workspace/output_gpu0 /workspace/cache_gpu0
  start_one comfy-8288 8288 0 /workspace/output_gpu0 /workspace/cache_gpu0
fi
if [ "$gpus" -ge 2 ]; then
  mkdir -p /workspace/output_gpu1 /workspace/cache_gpu1
  start_one comfy-8388 8388 1 /workspace/output_gpu1 /workspace/cache_gpu1
fi

sleep 5
tmux ls
SH
chmod +x /workspace/run_comfy_mux.sh

if /workspace/run_comfy_mux.sh; then
  tg "✅ ComfyUI up on 8188, 8288 (GPU0), 8388 (GPU1 if present)."
else
  tg "⚠️ ComfyUI launch had warnings. Check /workspace/logs/."
fi

echo "Bootstrap complete. Logs: /workspace/logs  |  Bootstrap: /workspace/bootstrap_run.log"
sleep infinity
