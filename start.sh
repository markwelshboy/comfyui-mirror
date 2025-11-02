#!/usr/bin/env bash
set -euo pipefail

# ---------- A) Pre-flight ----------
# tcmalloc (robust)
TCMALLOC="$(ldconfig -p 2>/dev/null | awk '/libtcmalloc.so/{print $NF; exit} /libtcmalloc_minimal.so/{print $NF; exit}')"
if [[ -n "${TCMALLOC:-}" && -f "$TCMALLOC" ]]; then
  export LD_PRELOAD="$TCMALLOC"
else
  echo "tcmalloc not found; continuing without LD_PRELOAD"
fi

# Optional user hook
if [[ -f "/workspace/additional_params.sh" ]]; then
  chmod +x /workspace/additional_params.sh
  echo "Executing additional_params.sh..."
  /workspace/additional_params.sh
else
  echo "additional_params.sh not found; skipping…"
fi

# Make sure tools exist (image should already have them; this is extra-safe)
command -v aria2c >/dev/null || (apt-get update && apt-get install -y aria2)
command -v curl   >/dev/null || (apt-get update && apt-get install -y curl)

# ---------- SageAttention (background build, exact commit) ----------
echo "Starting SageAttention build…"
(
  export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
  cd /tmp
  rm -rf SageAttention
  git clone https://github.com/thu-ml/SageAttention.git
  cd SageAttention
  git reset --hard 68de379
  pip install -e .
  echo "done" > /tmp/sage_build_done
) > /tmp/sage_build.log 2>&1 &
SAGE_PID=$!
echo "SageAttention building in background (PID $SAGE_PID)"

# ---------- B) Workspace + Jupyter ----------
NETWORK_VOLUME="/workspace"
if [[ ! -d "$NETWORK_VOLUME" ]]; then
  echo "No /workspace volume; using /"
  NETWORK_VOLUME="/"
fi
JUP_DIR="$NETWORK_VOLUME"
echo "Starting JupyterLab on $JUP_DIR"
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
  --notebook-dir="$JUP_DIR" >/dev/null 2>&1 &

COMFY_DIR_SYS="/ComfyUI"
COMFY_DIR_VOL="$NETWORK_VOLUME/ComfyUI"
if [[ ! -d "$COMFY_DIR_VOL" ]]; then
  mv "$COMFY_DIR_SYS" "$COMFY_DIR_VOL"
else
  echo "ComfyUI already present in $COMFY_DIR_VOL; skip move"
fi

# ---------- C) Utilities + specific custom nodes ----------
echo "Installing CivitAI downloader…"
rm -rf /tmp/CivitAI_Downloader
git clone https://github.com/Hearmeman24/CivitAI_Downloader.git /tmp/CivitAI_Downloader
install -m 0755 /tmp/CivitAI_Downloader/download_with_aria.py /usr/local/bin/
rm -rf /tmp/CivitAI_Downloader
pip install --no-cache-dir onnxruntime-gpu &

CUSTOM="$COMFY_DIR_VOL/custom_nodes"
mkdir -p "$CUSTOM"
# clone-or-pull helper
clone_or_pull () {
  local repo="$1" dst="$2"
  if [[ -d "$dst/.git" ]]; then
    echo "Updating $(basename "$dst")"
    git -C "$dst" pull --ff-only || true
  else
    git clone "$repo" "$dst"
  fi
}
clone_or_pull https://github.com/kijai/ComfyUI-WanVideoWrapper.git      "$CUSTOM/ComfyUI-WanVideoWrapper"
clone_or_pull https://github.com/kijai/ComfyUI-KJNodes.git              "$CUSTOM/ComfyUI-KJNodes"
clone_or_pull https://github.com/wildminder/ComfyUI-VibeVoice.git       "$CUSTOM/ComfyUI-VibeVoice"
clone_or_pull https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git "$CUSTOM/ComfyUI-WanAnimatePreprocess"

# Parallel requirements installs
pip install --no-cache-dir -r "$CUSTOM/ComfyUI-KJNodes/requirements.txt"              &
PID_KJ=$!
pip install --no-cache-dir -r "$CUSTOM/ComfyUI-WanVideoWrapper/requirements.txt"      &
PID_WAN=$!
pip install --no-cache-dir -r "$CUSTOM/ComfyUI-VibeVoice/requirements.txt"            &
PID_VIBE=$!
pip install --no-cache-dir -r "$CUSTOM/ComfyUI-WanAnimatePreprocess/requirements.txt" &
PID_WANANIM=$!

# ---------- D) Model downloads (same env flags) ----------
dl() { # url dest
  local url="$1" dest="$2" dir; dir="$(dirname "$dest")"; mkdir -p "$dir"
  # delete small/corrupt or leftover .aria2
  if [[ -f "$dest" ]]; then
    local sz; sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
    (( sz < 10485760 )) && rm -f "$dest"
  fi
  [[ -f "${dest}.aria2" ]] && rm -f "${dest}.aria2" "$dest"
  aria2c -x 16 -s 16 -k 1M --continue=true -d "$dir" -o "$(basename "$dest")" "$url" &
}

DM="$COMFY_DIR_VOL/models/diffusion_models"
TE="$COMFY_DIR_VOL/models/text_encoders"
CV="$COMFY_DIR_VOL/models/clip_vision"
VAE="$COMFY_DIR_VOL/models/vae"
LR="$COMFY_DIR_VOL/models/loras"
DET="$COMFY_DIR_VOL/models/detection"
UNION="$COMFY_DIR_VOL/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
mkdir -p "$DM" "$TE" "$CV" "$VAE" "$LR" "$DET" "$UNION"

# (… replicate the same if-blocks you pasted; omitted here for brevity …)
# Example: Wan2.2 gate
if [[ "${download_wan22:-false}" == "true" ]]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "$DM/wan2.2_t2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"  "$DM/wan2.2_t2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$DM/wan2.2_i2v_high_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors"  "$DM/wan2.2_i2v_low_noise_14B_fp16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors"                                 "$VAE/wan2.2_vae.safetensors"
fi

# Download 480p native models
if [ "${download_480p_native_models:-false}" == "true" ]; then
  echo "Downloading 480p native models..."
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DM/wan2.1_i2v_480p_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DM/wan2.1_t2v_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DM/wan2.1_t2v_1.3B_bf16.safetensors"
fi

if [ "${debug_models:-false}" == "true" ]; then
  echo "Downloading 480p native models..."
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors" "$DM/wan2.1_i2v_480p_14B_fp16.safetensors"
fi

# Handle full download (with SDXL)
if [ "${download_wan_fun_and_sdxl_helper:-false}" == "true" ]; then
  echo "Downloading Wan Fun 14B Model"
  dl "https://huggingface.co/alibaba-pai/Wan2.1-Fun-14B-Control/resolve/main/diffusion_pytorch_model.safetensors" "$DM/diffusion_pytorch_model.safetensors"

  if [ ! -f "$UNION/diffusion_pytorch_model_promax.safetensors" ]; then
    dl "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$UNION/diffusion_pytorch_model_promax.safetensors"
  fi
fi

if [ "${download_vace:-false}" == "true" ]; then
  echo "Downloading Wan 1.3B and 14B"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DM/wan2.1_t2v_1.3B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DM/wan2.1_t2v_14B_bf16.safetensors"
  echo "Downloading VACE 14B Model"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors" "$DM/Wan2_1-VACE_module_14B_bf16.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors" "$DM/Wan2_1-VACE_module_1_3B_bf16.safetensors"
fi

if [ "${download_vace_debug:-false}" == "true" ]; then
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "$DM/wan2.1_vace_14B_fp16.safetensors"
fi

# Download 720p native models
if [ "${download_720p_native_models:-false}" == "true" ]; then
  echo "Downloading 720p native models..."
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DM/wan2.1_i2v_720p_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DM/wan2.1_t2v_14B_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DM/wan2.1_t2v_1.3B_bf16.safetensors"
fi

# Download Wan Animate model
if [ "${download_wan_animate:-false}" == "true" ]; then
  echo "Downloading Wan Animate model..."
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" "$DM/wan2.2_animate_14B_bf16.safetensors"
  # Download detection models for WanAnimatePreprocess
  echo "Downloading detection models..."
  dl "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$DET/yolov10m.onnx"
  dl "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$DET/vitpose_h_wholebody_data.bin"
  dl "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$DET/vitpose_h_wholebody_model.onnx"
fi

if [ "${download_text_encoders:-false}" == "true" ]; then
  # Download text encoders
  echo "Downloading text encoders..."
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TE/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TE/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TE/umt5-xxl-enc-bf16.safetensors"
fi

mkdir -p "$CLIP_VISION_DIR"
if [ "${download_clip_vision:-false}" == "true" ]; then
  # Create CLIP vision directory and download models
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CV/clip_vision_h.safetensors"
fi

if [ "${download_vae:-false}" == "true" ]; then
  # Download VAE
  echo "Downloading VAE..."
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE/Wan2_1_VAE_bf16.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE/wan_2.1_vae.safetensors"
fi

if [ "${download_optimization_loras:-false}" == "true" ]; then
  echo "Downloading optimization loras"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "$LR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "$LR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"
  dl "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors" "$LR/wan2.2_animate_14B_relight_lora_bf16.safetensors"
  dl "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" "$LR/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
  dl "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/high_noise_model.safetensors" "$LR/t2v_lightx2v_high_noise_model.safetensors"
  dl "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" "$LR/t2v_lightx2v_low_noise_model.safetensors"
  dl "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LR/i2v_lightx2v_high_noise_model.safetensors"
  dl "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LR/i2v_lightx2v_low_noise_model.safetensors"
fi

# CivitAI batches
IFS=',' read -r -a CP_IDS <<< "${CHECKPOINT_IDS_TO_DOWNLOAD:-}"
IFS=',' read -r -a LR_IDS <<< "${LORAS_IDS_TO_DOWNLOAD:-}"
for id in "${CP_IDS[@]}"; do (cd "$COMFY_DIR_VOL/models/checkpoints" && download_with_aria.py -m "$id") & done
for id in "${LR_IDS[@]}"; do (cd "$LR"                              && download_with_aria.py -m "$id") & done

# Move 4xLSDIR if present
if [[ ! -f "$COMFY_DIR_VOL/models/upscale_models/4xLSDIR.pth" && -f "/4xLSDIR.pth" ]]; then
  mkdir -p "$COMFY_DIR_VOL/models/upscale_models"
  mv "/4xLSDIR.pth" "$COMFY_DIR_VOL/models/upscale_models/4xLSDIR.pth"
fi

# Wait for all aria2c to finish
while pgrep -x aria2c >/dev/null; do
  echo "🔽 Model downloads in progress…"
  sleep 5
done

# ---------- E) Workflows + UI tweaks ----------
WF_SRC="/comfyui-wan/workflows"
WF_DST="$COMFY_DIR_VOL/user/default/workflows"
mkdir -p "$WF_DST"
if [[ -d "$WF_SRC" ]]; then
  for dir in "$WF_SRC"/*/; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    if [[ -e "$WF_DST/$base" ]]; then
      rm -rf "$dir"
    else
      mv "$dir" "$WF_DST/"
    fi
  done
fi

if [[ "${change_preview_method:-false}" == "true" ]]; then
  sed -i "/id: *'VHS.LatentPreview'/,/defaultValue:/s/defaultValue: false/defaultValue: true/" \
    "$CUSTOM/ComfyUI-VideoHelperSuite/web/js/VHS.core.js" || true
  CFG_DIR="/ComfyUI/user/default/ComfyUI-Manager"
  CFG="$CFG_DIR/config.ini"
  mkdir -p "$CFG_DIR"
  if [[ ! -f "$CFG" ]]; then
    cat > "$CFG" <<'INI'
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
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CFG" || true
  fi
fi

echo "cd $NETWORK_VOLUME" >> ~/.bashrc || true

# ---------- F) Waits + launch ----------
wait $PID_KJ || { echo "❌ KJNodes install failed"; exit 1; }
wait $PID_WAN || { echo "❌ WanVideoWrapper install failed"; exit 1; }
wait $PID_VIBE || { echo "❌ VibeVoice install failed"; exit 1; }
wait $PID_WANANIM || { echo "❌ WanAnimatePreprocess install failed"; exit 1; }

# rename .zip -> .safetensors in loras
if compgen -G "$LR/*.zip" >/dev/null; then
  (cd "$LR" && for f in *.zip; do mv "$f" "${f%.zip}.safetensors"; done)
fi

# Wait SageAttention completion (or bail gracefully)
echo "Waiting for SageAttention build…"
while [[ ! -f /tmp/sage_build_done ]]; do
  if ps -p "$SAGE_PID" >/dev/null 2>&1; then
    echo "⚙️  SageAttention building…"
    sleep 5
  else
    echo "⚠️  SageAttention ended unexpectedly; see /tmp/sage_build.log"
    break
  fi
done
[[ -f /tmp/sage_build_done ]] && echo "✅ SageAttention built"

## Start ComfyUI
#PORT="${PORT:-8188}"
#URL="http://127.0.0.1:${PORT}"
#echo "▶️  Starting ComfyUI on 0.0.0.0:${PORT}"
#nohup python3 "$COMFY_DIR_VOL/main.py" --listen --port "$PORT" --use-sage-attention \
#  > "$NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID:-local}_nohup.log" 2>&1 &

# readiness probe (max ~45s)
#for i in {1..45}; do
#  if curl -fsS "$URL" >/dev/null 2>&1; then
#    echo "🚀 ComfyUI is UP"
#    break
#  fi
#  echo "🔄 ComfyUI starting… logs: $NETWORK_VOLUME/comfyui_${RUNPOD_POD_ID:-local}_nohup.log"
#  sleep 1
#done

# ================== MULTI-INSTANCE / MULTI-GPU LAUNCH (tmux + Telegram) ==================

set +e  # don't die on curl/tmux checks

COMFY_ROOT="$NETWORK_VOLUME/ComfyUI"
LOG_DIR="$NETWORK_VOLUME/logs"
mkdir -p "$LOG_DIR"

# Per-instance dirs
OUT_8188="$NETWORK_VOLUME/output"
CACHE_8188="$NETWORK_VOLUME/cache"
OUT_8288="$NETWORK_VOLUME/output_gpu0"
CACHE_8288="$NETWORK_VOLUME/cache_gpu0"
OUT_8388="$NETWORK_VOLUME/output_gpu1"
CACHE_8388="$NETWORK_VOLUME/cache_gpu1"

mkdir -p "$OUT_8188" "$CACHE_8188" "$OUT_8288" "$CACHE_8288" "$OUT_8388" "$CACHE_8388"

# --- helpers ---
send_telegram() {
  local text="$1"
  if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" >/dev/null 2>&1 || true
  fi
}

wait_ready() {
  # $1=port $2=timeout_seconds
  local port="$1" timeout="${2:-60}" url="http://127.0.0.1:${port}"
  local i=0
  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 1
    i=$((i+1))
    if (( i >= timeout )); then
      return 1
    fi
  done
  return 0
}

launch_instance() {
  # args: name session port gpu_id out_dir cache_dir log_file extra_args
  local name="$1" sess="$2" port="$3" gpu="$4" outdir="$5" cachedir="$6" logfile="$7"
  shift 7
  local extra="$*"

  # Build command
  local cmd="cd \"$COMFY_ROOT\" && \
XDG_CACHE_HOME=\"$cachedir\" CUDA_VISIBLE_DEVICES=\"$gpu\" \
python3 main.py --listen 0.0.0.0 --port \"$port\" --use-sage-attention \
  --output-directory \"$outdir\" $extra >> \"$logfile\" 2>&1"

  # Start tmux session
  if tmux has-session -t "$sess" 2>/dev/null; then
    tmux kill-session -t "$sess" 2>/dev/null || true
  fi
  tmux new-session -d -s "$sess" "bash -lc '$cmd'"

  # Initial readiness
  if wait_ready "$port" 60; then
    echo "[$name] UP on port $port" | tee -a "$logfile"
    send_telegram "🚀 ComfyUI: $name is UP on ${HOSTNAME:-pod} (port $port)"
  else
    echo "[$name] did not become ready within 60s" | tee -a "$logfile"
    send_telegram "⚠️ $name did not respond with HTTP 200 within 60s (port $port). Check logs: $logfile"
  fi

  # Crash/health monitor (background)
  (
    local was_up=0
    while true; do
      sleep 10
      # Check tmux session
      if ! tmux has-session -t "$sess" 2>/dev/null; then
        send_telegram "❌ $name tmux session exited (port $port). Log: $logfile"
        exit 0
      fi
      # Check HTTP health
      if curl -fsS "http://127.0.0.1:${port}" >/dev/null 2>&1; then
        was_up=1
      else
        # Only notify if it had been up at least once to avoid duplicate noise
        if (( was_up == 1 )); then
          send_telegram "❌ $name became unresponsive (port $port). Log: $logfile"
          exit 0
        fi
      fi
    done
  ) &

}

# --- detect GPU count ---
GPU_COUNT="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
[[ -z "$GPU_COUNT" || "$GPU_COUNT" -lt 0 ]] && GPU_COUNT=0

# --- launch instances ---
# 8188 (leave general settings "alone": no explicit GPU mask; still isolate outputs/cache/logs)
LOG_8188="$LOG_DIR/comfyui-8188.log"
launch_instance "ComfyUI-8188" "comfy-8188" 8188 "all" "$OUT_8188" "$CACHE_8188" "$LOG_8188" ""

# 8288 on GPU 0 always
LOG_8288="$LOG_DIR/comfyui-8288.log"
launch_instance "ComfyUI-8288 (GPU0)" "comfy-8288" 8288 "0" "$OUT_8288" "$CACHE_8288" "$LOG_8288" ""

# 8388 only if we have >=2 GPUs, bound to GPU 1
if (( GPU_COUNT >= 2 )); then
  LOG_8388="$LOG_DIR/comfyui-8388.log"
  launch_instance "ComfyUI-8388 (GPU1)" "comfy-8388" 8388 "1" "$OUT_8388" "$CACHE_8388" "$LOG_8388" ""
else
  echo "[Info] <2 GPUs detected; skipping ComfyUI-8388"
fi

# Keep container alive (tmux owns the processes)
sleep infinity

# ================== END MULTI-INSTANCE BLOCK ==================