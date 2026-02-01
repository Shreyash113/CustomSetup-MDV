# =============================================================================
# Base: CUDA 12.8 runtime (correct for cu128)
# =============================================================================
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# --- Optional cache env (good for HF/torch caches on /workspace volume)
ENV HF_HOME=/workspace/.cache/huggingface
ENV TRANSFORMERS_CACHE=/workspace/.cache/huggingface
ENV TORCH_HOME=/workspace/.cache/torch

# --- Common runtime variables
ENV IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg
ENV FILEBROWSER_CONFIG=/workspace/runpod-slim/.filebrowser.json

# =============================================================================
# System deps + Python 3.12
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    build-essential \
    git curl wget ca-certificates \
    openssh-server openssh-client \
    nano htop tmux less net-tools iputils-ping procps \
    ffmpeg \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev \
    && python3.12 -m ensurepip --upgrade \
    && python3.12 -m pip install -U pip wheel setuptools \
    && rm -rf /var/lib/apt/lists/*

# Make python3 -> python3.12
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --set python3 /usr/bin/python3.12

# =============================================================================
# Create a base venv in /opt/venv (image-baked)
# =============================================================================
ENV VENV=/opt/venv
RUN python3 -m venv $VENV
ENV PATH="$VENV/bin:$PATH"

# Pip tooling
RUN pip install -U pip wheel setuptools

# =============================================================================
# Install PyTorch cu128 (Python 3.12)
# =============================================================================
RUN pip install --index-url https://download.pytorch.org/whl/cu128 \
    torch torchvision torchaudio

# Quick sanity check (won't fail build if GPU not available at build time)
RUN python - <<'PY'
import torch
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available at build time:", torch.cuda.is_available())
PY

# =============================================================================
# Install ComfyUI + common deps (baked in)
# =============================================================================
RUN mkdir -p /workspace/runpod-slim
WORKDIR /workspace/runpod-slim

# Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git

# Custom nodes (baked)
RUN mkdir -p /workspace/runpod-slim/ComfyUI/custom_nodes && \
    cd /workspace/runpod-slim/ComfyUI/custom_nodes && \
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone https://github.com/kijai/ComfyUI-KJNodes && \
    git clone https://github.com/MoonGoblinDev/Civicomfy && \
    git clone https://github.com/Lightricks/ComfyUI-LTXVideo


# ComfyUI requirements + extra libs (baked)
RUN pip install -r /workspace/runpod-slim/ComfyUI/requirements.txt && \
    pip install GitPython opencv-python

# Install custom node requirements (baked, non-fatal)
RUN bash -lc 'cd /workspace/runpod-slim/ComfyUI/custom_nodes && \
  for d in */; do \
    if [ -f "$d/requirements.txt" ]; then \
      echo "Installing $d requirements"; \
      pip install --no-cache-dir -r "$d/requirements.txt" || true; \
    fi; \
  done'

# =============================================================================
# FileBrowser + Jupyter (optional utilities)
# =============================================================================
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash && \
    pip install jupyter

# SSH config
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd

# Ports
EXPOSE 8188 22 8888 8080

# Copy your start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]