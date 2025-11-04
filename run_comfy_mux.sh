#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/venv/bin:$PATH"
BASE=${COMFY}
LOGS=${COMFY_LOGS}

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
