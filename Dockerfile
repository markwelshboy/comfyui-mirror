# ---------- build base ----------
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    PATH="/opt/venv/bin:$PATH"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev python3-pip \
        curl ffmpeg ninja-build git aria2 git-lfs wget vim \
        libgl1 libglib2.0-0 build-essential gcc \
        # tcmalloc used by your start.sh
        google-perftools \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && python3.12 -m venv /opt/venv \
    && git lfs install --system \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Torch nightly for CUDA 12.8
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --pre torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/nightly/cu128

# Tooling + Jupyter (your script starts JupyterLab)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install packaging setuptools wheel \
               pyyaml gdown triton comfy-cli \
               jupyterlab jupyterlab-lsp jupyter-server jupyter-server-terminals \
               ipykernel jupyterlab_code_formatter

# ComfyUI workspace
RUN --mount=type=cache,target=/root/.cache/pip \
    /usr/bin/yes | comfy --workspace /ComfyUI install

# ---------- final image ----------
FROM base AS final
ENV PATH="/opt/venv/bin:$PATH"

# Some nodes need OpenCV
RUN --mount=type=cache,target=/root/.cache/pip pip install opencv-python

# (Optional) your custom nodes clone block can stay; the start.sh will add more.

# Put your files in-image
COPY 4xLSDIR.pth /4xLSDIR.pth
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188
EXPOSE 8288
EXPOSE 8388
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD curl -sf http://127.0.0.1:8188/ || exit 1

CMD ["/start.sh"]
