# ============================================================================
# Stage 1: Builder - Clone ComfyUI and install all Python packages
# ============================================================================
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install minimal dependencies needed for building
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    software-properties-common \
    gpg-agent \
    git \
    wget \
    curl \
    ca-certificates \
    && add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    build-essential \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-minimal-build-12-4 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb

# Install pip for Python 3.12 and upgrade it
RUN curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3.12 get-pip.py && \
    python3.12 -m pip install --upgrade pip setuptools wheel && \
    rm get-pip.py

# Set CUDA environment for building
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Clone ComfyUI to get requirements
WORKDIR /tmp/build
RUN git clone https://github.com/comfyanonymous/ComfyUI.git

# Clone custom nodes to get their requirements
WORKDIR /tmp/build/ComfyUI/custom_nodes
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git && \
    git clone https://github.com/MoonGoblinDev/Civicomfy && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone https://github.com/rgthree/rgthree-comfy.git && \
    git clone https://github.com/M1kep/ComfyLiterals.git && \
    git clone https://github.com/scofano/comfy-audio-duration.git && \
    \
    # ---- Added custom nodes ----
    git clone https://github.com/Lightricks/ComfyUI-LTXVideo.git && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git && \
    git clone https://github.com/WASasquatch/was-node-suite-comfyui.git

# Install PyTorch and all ComfyUI dependencies
RUN python3.12 -m pip install --no-cache-dir \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Triton (Linux wheel, Python 3.12 compatible)
RUN python3.12 -m pip install --no-cache-dir triton==3.2.0

# Optional: SageAttention v1 (if it fails on cp312/your combo, build will continue)
RUN python3.12 -m pip install --no-cache-dir sageattention==1.0.6 || true

# Preinstall huggingface_hub (for workflow sync in start.sh)
RUN python3.12 -m pip install --no-cache-dir -U huggingface_hub

# Optional sanity check (prints versions during build logs)
RUN python3.12 - << 'PY'
import torch
print("torch:", torch.__version__)
try:
    import triton
    print("triton:", triton.__version__)
except Exception as e:
    print("triton import failed:", e)
try:
    import huggingface_hub
    print("huggingface_hub:", huggingface_hub.__version__)
except Exception as e:
    print("huggingface_hub import failed:", e)
PY

WORKDIR /tmp/build/ComfyUI
RUN python3.12 -m pip install --no-cache-dir -r requirements.txt && \
    python3.12 -m pip install --no-cache-dir GitPython opencv-python

# Install custom node dependencies (best-effort)
WORKDIR /tmp/build/ComfyUI/custom_nodes
RUN for node_dir in */; do \
        if [ -f "$node_dir/requirements.txt" ]; then \
            echo "Installing requirements for $node_dir"; \
            python3.12 -m pip install --no-cache-dir -r "$node_dir/requirements.txt" || true; \
        fi; \
    done

# ============================================================================
# Stage 2: Runtime - Clean image with pre-installed packages
# ============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg
ENV FILEBROWSER_CONFIG=/workspace/runpod-slim/.filebrowser.json

# ----------------------------
# Model auto-download (TXT list)
# ----------------------------
ENV MODEL_LIST_URL=""
ENV HF_TOKEN=""
ENV HUGGINGFACEHUB_API_TOKEN=""

# ----------------------------
# HuggingFace Workflows sync (your repo)
# ----------------------------
ENV HF_WORKFLOWS_REPO="Shreyash113/workflows"
ENV HF_WORKFLOWS_SUBDIR=""

# Update and install runtime dependencies, CUDA, and common tools
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    software-properties-common \
    gpg-agent \
    && add-apt-repository ppa:deadsnakes/ppa && \
    add-apt-repository ppa:cybermax-dexter/ffmpeg-nvenc && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    build-essential \
    libssl-dev \
    wget \
    gnupg \
    xz-utils \
    openssh-client \
    openssh-server \
    nano \
    curl \
    htop \
    tmux \
    ca-certificates \
    less \
    net-tools \
    iputils-ping \
    procps \
    golang \
    make \
    && wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-minimal-build-12-4 \
    && apt-get install -y --no-install-recommends ffmpeg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm cuda-keyring_1.1-1_all.deb

# Copy Python packages and pip executables from builder stage
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin /usr/local/bin

# --- CRITICAL FIX: ensure pip exists in runtime and is discoverable ---
RUN python3.12 -m ensurepip --upgrade || true && \
    python3.12 -m pip install --upgrade pip setuptools wheel

# Remove uv to force ComfyUI-Manager to use pip
RUN python3.12 -m pip uninstall -y uv 2>/dev/null || true && \
    rm -f /usr/local/bin/uv /usr/local/bin/uvx

# Install FileBrowser
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Set CUDA environment variables
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Install Jupyter with Python kernel
RUN python3.12 -m pip install jupyter

# Configure SSH for root login
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    mkdir -p /run/sshd && \
    rm -f /etc/ssh/ssh_host_*

# Create workspace directory
RUN mkdir -p /workspace/runpod-slim
WORKDIR /workspace/runpod-slim

# Expose ports
EXPOSE 8188 22 8888 8080

# Copy start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Set Python 3.12 as default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --set python3 /usr/bin/python3.12

ENTRYPOINT ["/start.sh"]