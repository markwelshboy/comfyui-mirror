#!/usr/bin/env bash

set -euo pipefail

touch /root/.no_auto_tmux

# Always have a workspace
mkdir -p /workspace && cd /workspace

# OS deps we need BEFORE autorun
# Noninteractive apt
export DEBIAN_FRONTEND=noninteractive
umask 0022
apt-get update
apt-get install -y --no-install-recommends \
  python3.12 python3.12-venv python3-pip \
  git curl aria2 ffmpeg ninja-build build-essential gcc \
  libgl1 libglib2.0-0 tmux

# predictable names
ln -sf /usr/bin/python3.12 /usr/bin/python || true
ln -sf /usr/bin/pip3       /usr/bin/pip     || true

# pull your repo
if [ -d comfyui-mirror ]; then
  cd comfyui-mirror && git pull --rebase || true
else
  git clone https://github.com/markwelshboy/comfyui-mirror.git
  cd comfyui-mirror
fi

# where ComfyUI should live (persisted)
export COMFY_HOME="/workspace/ComfyUI"

# run bootstrap (its own logging)
bash autorun_vast_wan.sh > /workspace/bootstrap_run.log 2>&1
