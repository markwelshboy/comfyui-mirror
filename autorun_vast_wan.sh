#!/usr/bin/env bash
set -euo pipefail

# ----- 0) Basics -----
export DEBIAN_FRONTEND=noninteractive
mkdir -p /workspace && cd /workspace

# Tooling + venv path
export PATH="/opt/venv/bin:$PATH"
ln -sf /usr/bin/python3.12 /usr/bin/python || true
ln -sf /usr/bin/pip3     /usr/bin/pip     || true

apt-get update
apt-get install -y --no-install-recommends \
  git git-lfs curl aria2 ffmpeg ninja-build build-essential gcc \
  libgl1 libglib2.0-0 tmux vim google-perftools rsync
git lfs install --system || true

# ----- 1) Ensure ComfyUI present, normalize to /workspace -----
if [ ! -d /ComfyUI ]; then
  # If comfy-cli was used previously it may say "already installed". Force.
  pip install -U comfy-cli || true
  /usr/bin/yes | comfy --workspace /ComfyUI install --restore || true
fi

# Move to /workspace and leave a symlink at /ComfyUI for compatibility
if [ -d /ComfyUI ] && [ ! -e /workspace/ComfyUI ]; then
  rsync -aHAX --delete /ComfyUI/ /workspace/ComfyUI/
  mv /ComfyUI /ComfyUI.old || true
  ln -s /workspace/ComfyUI /ComfyUI
fi
[ -e /ComfyUI ] || ln -s /workspace/ComfyUI /ComfyUI

COMFY="/ComfyUI"
CUST="$COMFY/custom_nodes"
mkdir -p /workspace/logs "$COMFY/output" "$COMFY/cache" "$CUST"

# ----- 2) SageAttention (pin commit) -----
# Build in background early to save time.
if ! python -c 'import sageattention' >/dev/null 2>&1; then
  (
    set -xe
    export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
    cd /tmp
    rm -rf SageAttention
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention
    git reset --hard 68de379
    pip install -e .
    echo "ok" > /tmp/sage_ok
  ) > /workspace/logs/sage_build.log 2>&1 &
fi

# ----- 3) Helper to install nodes (+ requirements/install.py if present) -----
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
  if [ -f "$dest/requirements.txt" ]; then
    pip install --no-cache-dir -r "$dest/requirements.txt" || true
  fi
  if [ -f "$dest/install.py" ]; then
    python "$dest/install.py" || true
  fi
}

# ----- 4) The node set from your Hearmeman-based build -----
NODES=(
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
  # Extras from your newer start flow:
  https://github.com/wildminder/ComfyUI-VibeVoice.git
  https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git
)

for r in "${NODES[@]}"; do install_node "$r"; done

# ----- 5) Optional: switch VHS latent preview on by default -----
if [ "${change_preview_method:-true}" = "true" ]; then
  JS="$CUST/ComfyUI-VideoHelperSuite/web/js/VHS.core.js"
  if [ -f "$JS" ]; then
    sed -i "/id: *'VHS.LatentPreview'/,/defaultValue:/s/defaultValue: false/defaultValue: true/" "$JS" || true
  fi
  mkdir -p "$COMFY/user/default/ComfyUI-Manager"
  CFG="$COMFY/user/default/ComfyUI-Manager/config.ini"
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

# ----- 6) WAN models (same URLs as your earlier script) controlled by env flags -----
# Set these in Vast env if you want auto-downloads:
#   download_wan22=true
#   download_vace=true
#   download_480p_native_models=true
#   download_720p_native_models=true
#   download_wan_animate=true
#   debug_models=true
DIFF="$COMFY/models/diffusion_models"
TEXT="$COMFY/models/text_encoders"
CLIPV="$COMFY/models/clip_vision"
VAE="$COMFY/models/vae"
LORA="$COMFY/models/loras"
DET="$COMFY/models/detection"
CTRL="$COMFY/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
mkdir -p "$DIFF" "$TEXT" "$CLIPV" "$VAE" "$LORA" "$DET" "$CTRL" /workspace/ComfyUI/models/upscale_models

dl() { aria2c -x16 -s16 -k1M --continue=true -d "$(dirname "$2")" -o "$(basename "$2")" "$1"; }

if [ "${download_wan22:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "$DIFF/wan2.2_t2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" "$DIFF/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$DIFF/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" "$DIFF/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors" "$DIFF/wan2.2_ti2v_5B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors" "$VAE/wan2.2_vae.safetensors"
fi
if [ "${download_vace:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFF/wan2.1_t2v_1.3B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFF/wan2.1_t2v_14B_bf16.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors" "$DIFF/Wan2_1-VACE_module_14B_bf16.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors" "$DIFF/Wan2_1-VACE_module_1_3B_bf16.safetensors"
fi
if [ "${download_480p_native_models:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DIFF/wan2.1_i2v_480p_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFF/wan2.1_t2v_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFF/wan2.1_t2v_1.3B_bf16.safetensors"
fi
if [ "${download_720p_native_models:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DIFF/wan2.1_i2v_720p_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFF/wan2.1_t2v_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFF/wan2.1_t2v_1.3B_bf16.safetensors"
fi
if [ "${download_wan_animate:-false}" = "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" "$DIFF/wan2.2_animate_14B_bf16.safetensors"
fi
# Text encoders / clip vision / VAE
dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TEXT/umt5_xxl_fp8_e4m3fn_scaled.safetensors" || true
dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" || true
dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TEXT/umt5-xxl-enc-bf16.safetensors" || true
mkdir -p "$CLIPV"
dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIPV/clip_vision_h.safetensors" || true
dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE/Wan2_1_VAE_bf16.safetensors" || true
dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE/wan_2.1_vae.safetensors" || true

# Detection models for WanAnimatePreprocess
dl "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$DET/yolov10m.onnx" || true
dl "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$DET/vitpose_h_wholebody_data.bin" || true
dl "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$DET/vitpose_h_wholebody_model.onnx" || true

# Upscale model (4xLSDIR) if present in image at root (like your Dockerfile)
if [ -f "/4xLSDIR.pth" ] && [ ! -f "$COMFY/models/upscale_models/4xLSDIR.pth" ]; then
  mv "/4xLSDIR.pth" "$COMFY/models/upscale_models/4xLSDIR.pth"
fi

# ----- 7) Wait for SageAttention, then start mux -----
echo "Waiting for SageAttention build..."
for i in $(seq 1 120); do
  if [ -f /tmp/sage_ok ]; then break; fi
  sleep 2
done

# Telegram helper
tg() {
  if [ -n "${TELEGRAM_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$1" >/dev/null || true
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

# GPU split
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

# Watch sessions; if any dies, exit nonzero (so a supervisor could alert)
sleep 5
tmux ls
SH
chmod +x /workspace/run_comfy_mux.sh

# Launch and notify
if /workspace/run_comfy_mux.sh; then
  tg "✅ ComfyUI instances are up on 8188 (default), 8288 (GPU0), 8388 (GPU1 if present)."
else
  tg "⚠️ ComfyUI launch had warnings/failures. Check /workspace/logs/ and comfyui-*.log."
fi

echo "All set. Logs: /workspace/logs , bootstrap log: /workspace/bootstrap_run.log"
sleep infinity
