#!/usr/bin/env bash
set -euo pipefail

# ------------------------
# 0) Basics & workspace
# ------------------------
export DEBIAN_FRONTEND=noninteractive
mkdir -p /workspace && cd /workspace

apt-get update
apt-get install -y --no-install-recommends \
  python3.12 python3.12-venv python3.12-dev python3-pip \
  curl git git-lfs aria2 ffmpeg ninja-build build-essential gcc \
  libgl1 libglib2.0-0 tmux vim
git lfs install --system || true

# Predictable python/pip names (some images already link these; safe to try)
ln -sf /usr/bin/python3.12 /usr/bin/python || true
ln -sf /usr/bin/pip3     /usr/bin/pip     || true

# ------------------------
# 1) Clone/Update your repo
# ------------------------
if [ -d comfyui-mirror/.git ]; then
  (cd comfyui-mirror && git pull --rebase --autostash || true)
else
  git clone https://github.com/markwelshboy/comfyui-mirror.git
fi
cd comfyui-mirror

# ------------------------
# 2) Python venv + Torch cu128
# ------------------------
python -m venv /opt/venv
export PATH="/opt/venv/bin:$PATH"
python -m pip install -U pip wheel setuptools

# Nightly Torch for CUDA 12.8
pip install --pre torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/nightly/cu128

# Core runtime
pip install packaging pyyaml gdown triton comfy-cli \
            jupyterlab jupyterlab-lsp jupyter-server jupyter-server-terminals \
            ipykernel jupyterlab_code_formatter opencv-python

# ------------------------
# 3) Install ComfyUI to /ComfyUI (as your scripts expect)
# ------------------------
/usr/bin/yes | comfy --workspace ComfyUI install || true

# Normalize ComfyUI location to /workspace with a symlink at /ComfyUI
mkdir -p /workspace
if [ -d /ComfyUI ] && [ ! -e /workspace/ComfyUI ]; then
  rsync -aHAX --delete /ComfyUI/ /workspace/ComfyUI/
  mv /ComfyUI /ComfyUI.old || true
  ln -s /workspace/ComfyUI /ComfyUI
fi
[ -e /ComfyUI ] || ln -s /workspace/ComfyUI /ComfyUI

# ------------------------
# 4) Run your bootstrap (does downloads, nodes, etc.)
# ------------------------
bash bootstrap_vast.sh 2>&1 | tee /workspace/bootstrap_run.log

# ------------------------
# 5) Start multi-instance ComfyUI via tmux
#    - 8188 default
#    - 8288 pinned to GPU 0
#    - 8388 pinned to GPU 1 (if present)
# ------------------------
cat >/workspace/run_comfy_mux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
BASE=/workspace/ComfyUI
LOGS=/workspace/logs
mkdir -p "$LOGS" "$BASE/output" "$BASE/cache"

gpus=$(python3 - <<'PY'
try:
    import torch
    print(torch.cuda.device_count())
except Exception:
    print(0)
PY
)

healthwait() {
  local name=$1 port=$2
  local t=0
  until curl -fsS "http://127.0.0.1:${port}" >/dev/null 2>&1; do
    sleep 2; t=$((t+2))
    [ $t -ge 60 ] && echo "WARN: ${name} on ${port} not 200 after 60s." && return 1
  done
  echo "OK: ${name} is UP on :${port}"
}

start_one() {
  local name=$1 port=$2 gpu=$3
  local out="/workspace/output_${name}"
  local cache="/workspace/cache_${name}"
  mkdir -p "$out" "$cache"
  tmux new-session -d -s "comfy-${port}" \
    "CUDA_VISIBLE_DEVICES=${gpu} PYTHONUNBUFFERED=1 \
     python3 ${BASE}/main.py --listen --port ${port} \
       --output-directory ${out} --temp-directory ${cache} --use-sage-attention \
       >> ${LOGS}/comfyui-${port}.log 2>&1"
  ( healthwait "ComfyUI(${name})" "${port}" ) &
}

# 8188 default
tmux new-session -d -s comfy-8188 \
  "PYTHONUNBUFFERED=1 python3 ${BASE}/main.py --listen --port 8188 \
   --output-directory ${BASE}/output --temp-directory ${BASE}/cache --use-sage-attention \
   >> ${LOGS}/comfyui-8188.log 2>&1"
( healthwait "ComfyUI(default)" 8188 ) &

# 8288 on GPU 0
if [ "${gpus}" -ge 1 ]; then
  start_one "gpu0" 8288 0
fi
# 8388 on GPU 1 if present
if [ "${gpus}" -ge 2 ]; then
  start_one "gpu1" 8388 1
fi

wait || true
SH
chmod +x /workspace/run_comfy_mux.sh
bash /workspace/run_comfy_mux.sh

# ------------------------
# 6) Never exit (so Vast doesn't restart)
# ------------------------
echo "Autorun done. Tail logs in /workspace/logs/ or /workspace/bootstrap_run.log"
sleep infinity
