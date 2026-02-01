#!/bin/bash
set -e

# Use baked venv from Docker image (Python 3.12 + torch cu128)
source /opt/venv/bin/activate

# -----------------------------
# Paths
# -----------------------------
BASE_DIR="/workspace/runpod-slim"
COMFYUI_DIR="$BASE_DIR/ComfyUI"
DB_FILE="$BASE_DIR/filebrowser.db"
ARGS_FILE="$BASE_DIR/comfyui_args.txt"

# -----------------------------
# Helpers
# -----------------------------
log() { echo -e "\n==== $1 ====\n"; }

setup_ssh() {
  mkdir -p /root/.ssh

  # Host keys
  for type in rsa ecdsa ed25519; do
    if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
      ssh-keygen -t "${type}" -f "/etc/ssh/ssh_host_${type}_key" -q -N ''
    fi
  done

  if [[ -n "${PUBLIC_KEY:-}" ]]; then
    echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    echo "[SSH] Using PUBLIC_KEY auth"
  else
    if command -v openssl >/dev/null 2>&1; then
      RANDOM_PASS=$(openssl rand -base64 12)
    else
      RANDOM_PASS=$(date +%s | sha256sum | head -c 16)
    fi
    echo "root:${RANDOM_PASS}" | chpasswd
    echo "[SSH] Generated root password: ${RANDOM_PASS}"
  fi

  echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config || true
  /usr/sbin/sshd
}

export_env_vars() {
  log "Exporting environment variables for SSH/Jupyter shells"

  ENV_FILE="/etc/environment"
  SSH_ENV_FILE="/root/.ssh/environment"
  RP_ENV="/etc/rp_environment"

  mkdir -p /root/.ssh
  : > "$ENV_FILE"
  : > "$SSH_ENV_FILE"
  : > "$RP_ENV"

  printenv | grep -E '^(RUNPOD_|PATH=|CUDA|LD_LIBRARY_PATH|PYTHONPATH|HF_|TRANSFORMERS_|TORCH_|MODEL_LIST_URL=)' \
    | while read -r line; do
        name="${line%%=*}"
        value="${line#*=}"
        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_FILE"
        echo "export $name=\"$value\"" >> "$RP_ENV"
      done

  echo 'source /etc/rp_environment' >> /root/.bashrc || true
  echo 'source /etc/rp_environment' >> /etc/bash.bashrc || true

  chmod 644 "$ENV_FILE" || true
  chmod 600 "$SSH_ENV_FILE" || true
}

start_jupyter() {
  log "Starting JupyterLab on :8888"
  mkdir -p /workspace
  nohup jupyter lab \
    --allow-root \
    --no-browser \
    --port=8888 \
    --ip=0.0.0.0 \
    --FileContentsManager.delete_to_trash=False \
    --ServerApp.root_dir=/workspace \
    --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
    --ServerApp.allow_origin=* \
    &> /jupyter.log &
}

start_filebrowser() {
  log "Starting FileBrowser on :8080"
  mkdir -p "$BASE_DIR"

  if [ ! -f "$DB_FILE" ]; then
    echo "[FileBrowser] Initializing new config/db"
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin

    # move db into persistent volume (if created at default location)
    if [ -f "/root/.filebrowser.db" ]; then
      mv /root/.filebrowser.db "$DB_FILE" || true
    fi
  else
    echo "[FileBrowser] Using existing db: $DB_FILE"
  fi

  nohup filebrowser -d "$DB_FILE" &> /filebrowser.log &
}

# Optional: only install missing tools (fast + safe)
ensure_tools() {
  log "Ensuring basic tools"
  apt-get update
  apt-get install -y --no-install-recommends git aria2 curl openssh-server ca-certificates || true
  mkdir -p /run/sshd || true
}

verify_torch_cuda() {
  log "Verifying torch + CUDA"
  python - <<'PY'
import torch
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available inside container. Check GPU allocation / container runtime.")
PY
}

clone_comfyui_and_nodes() {
  log "Ensuring ComfyUI + custom nodes exist"
  mkdir -p "$BASE_DIR"
  cd "$BASE_DIR"

  if [ ! -d "$COMFYUI_DIR" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git
  else
    echo "[OK] ComfyUI already exists"
  fi

  mkdir -p "$COMFYUI_DIR/custom_nodes"

  if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
    cd "$COMFYUI_DIR/custom_nodes"
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git
  fi

  CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/MoonGoblinDev/Civicomfy"
    "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
  )

  for repo in "${CUSTOM_NODES[@]}"; do
    name="$(basename "$repo")"
    if [ ! -d "$COMFYUI_DIR/custom_nodes/$name" ]; then
      cd "$COMFYUI_DIR/custom_nodes"
      git clone "$repo"
    else
      echo "[OK] $name exists"
    fi
  done
}

install_deps_once() {
  log "Installing/refreshing ComfyUI + node requirements"
  pip install -r "$COMFYUI_DIR/requirements.txt"

  cd "$COMFYUI_DIR/custom_nodes"
  for node_dir in */; do
    [ -d "$node_dir" ] || continue
    cd "$COMFYUI_DIR/custom_nodes/$node_dir"

    if [ -f "requirements.txt" ]; then
      echo "[Deps] $node_dir requirements.txt"
      pip install --no-cache-dir -r requirements.txt || true
    fi
    if [ -f "install.py" ]; then
      echo "[Deps] $node_dir install.py"
      python install.py || true
    fi
    if [ -f "setup.py" ]; then
      echo "[Deps] $node_dir setup.py"
      pip install --no-cache-dir -e . || true
    fi
  done
}

create_model_folders() {
  log "Creating ComfyUI model folders"
  mkdir -p \
    "$COMFYUI_DIR/models/diffusion_models" \
    "$COMFYUI_DIR/models/loras" \
    "$COMFYUI_DIR/models/vae" \
    "$COMFYUI_DIR/models/text_encoders" \
    "$COMFYUI_DIR/models/wav2vec2" \
    "$COMFYUI_DIR/models/latent_upscale_models"
}

autodownload_models_from_list() {
  log "Auto-downloading models (MODEL_LIST_URL)"

  if [ -z "${MODEL_LIST_URL:-}" ]; then
    echo "[SKIP] MODEL_LIST_URL not set"
    return 0
  fi

  echo "[INFO] Fetching: $MODEL_LIST_URL"
  curl -L "$MODEL_LIST_URL" -o /tmp/model_list.txt

  dl_if_missing () {
    url="$1"
    out="$2"
    mkdir -p "$(dirname "$out")"
    if [ -f "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -gt 1048576 ]; then
      echo "[OK] $out"
    else
      echo "[DL] $url -> $out"
      aria2c -x 16 -s 16 -k 1M -o "$(basename "$out")" -d "$(dirname "$out")" "$url"
    fi
  }

  while read -r url relpath; do
    [ -z "$url" ] && continue
    case "$url" in \#*) continue ;; esac
    dl_if_missing "$url" "$COMFYUI_DIR/$relpath"
  done < /tmp/model_list.txt
}

start_comfyui() {
  log "Starting ComfyUI on :8188"

  if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created $ARGS_FILE"
  fi

  cd "$COMFYUI_DIR"
  FIXED_ARGS="--listen 0.0.0.0 --port 8188"
  CUSTOM_ARGS="$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ' | xargs || true)"

  if [ -n "$CUSTOM_ARGS" ]; then
    echo "[ComfyUI] Extra args: $CUSTOM_ARGS"
    nohup python main.py $FIXED_ARGS $CUSTOM_ARGS &> "$BASE_DIR/comfyui.log" &
  else
    nohup python main.py $FIXED_ARGS &> "$BASE_DIR/comfyui.log" &
  fi

  tail -f "$BASE_DIR/comfyui.log"
}

# -----------------------------
# Main
# -----------------------------
mkdir -p "$BASE_DIR"

ensure_tools
setup_ssh
export_env_vars

command -v filebrowser >/dev/null 2>&1 && start_filebrowser || echo "[SKIP] filebrowser not installed"
command -v jupyter >/dev/null 2>&1 && start_jupyter || echo "[SKIP] jupyter not installed"

verify_torch_cuda
clone_comfyui_and_nodes
install_deps_once
create_model_folders
autodownload_models_from_list

start_comfyui