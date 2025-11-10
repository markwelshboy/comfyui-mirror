#!/usr/bin/env bash

set -euo pipefail

touch /root/.no_auto_tmux

# Always have a workspace
mkdir -p /workspace && cd /workspace

# ---- Sanity check base image (need Ubuntu 24.04 for python3.12) ----
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "Base image: $PRETTY_NAME"
  if [ "$ID" != "ubuntu" ] || [ "${VERSION_ID%%.*}" -lt 24 ]; then
    echo "ERROR: This on-start script expects Ubuntu 24.04+ (for python3.12 apt packages)." >&2
    echo "       Please pick a CUDA image ending in -ubuntu24.04 in Vast." >&2
    exit 1
  fi
else
  echo "WARNING: /etc/os-release not found; continuing but python3.12 packages may be missing." >&2
fi

# ---- Install OS deps, pull repo, run bootstrap ----
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
