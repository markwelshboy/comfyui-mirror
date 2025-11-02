#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  python3.12 python3.12-venv python3.12-dev python3-pip \
  curl git git-lfs aria2 ffmpeg ninja-build build-essential gcc \
  libgl1 libglib2.0-0 tmux nano vim google-perftools
git lfs install --system || true

ln -sf /usr/bin/python3.12 /usr/bin/python || true
ln -sf /usr/bin/pip3 /usr/bin/pip || true

mkdir -p /workspace && cd /workspace
[ -d comfyui-mirror ] || git clone https://github.com/markwelshboy/comfyui-mirror.git
cd comfyui-mirror

python -m venv /opt/venv
export PATH=/opt/venv/bin:$PATH
python -m pip install --upgrade pip wheel setuptools

pip install --pre torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/nightly/cu128
pip install packaging pyyaml gdown triton comfy-cli \
  jupyterlab jupyterlab-lsp jupyter-server jupyter-server-terminals \
  ipykernel jupyterlab_code_formatter opencv-python

yes | comfy --workspace /ComfyUI install

chmod +x start.sh
export download_wan22="${download_wan22:-true}"
export change_preview_method="${change_preview_method:-true}"
exec ./start.sh
