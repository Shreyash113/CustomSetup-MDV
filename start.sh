#!/bin/bash
set -e

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"

TRITON_VERSION="${TRITON_VERSION:-3.2.0}"
SAGEATTN_VERSION="${SAGEATTN_VERSION:-1.0.6}"

# HuggingFace Workflows (repo is public; token optional)
HF_WORKFLOWS_REPO="${HF_WORKFLOWS_REPO:-Shreyash113/workflows}"
HF_WORKFLOWS_SUBDIR="${HF_WORKFLOWS_SUBDIR:-}"  # keep empty since your JSON is in repo root

# Will be set after venv activation
PYBIN="python3.12"

ensure_pip_tools() {
    echo "Ensuring pip is available..."
    python -m ensurepip --upgrade >/dev/null 2>&1 || true

    if ! python -m pip --version >/dev/null 2>&1; then
        echo "pip missing, bootstrapping via get-pip.py..."
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        python /tmp/get-pip.py
        rm -f /tmp/get-pip.py
    fi

    python -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
    echo "pip OK: $(python -m pip --version || true)"
}

ensure_perf_tools() {
    echo "Ensuring Triton + SageAttention in active environment..."
    python -m pip install --no-cache-dir -U "triton==${TRITON_VERSION}" >/dev/null 2>&1 || true
    python -m pip install --no-cache-dir -U "sageattention==${SAGEATTN_VERSION}" >/dev/null 2>&1 || true

    python - <<'PY' || true
import sys
print("python:", sys.version.split()[0])
try:
    import triton
    print("triton:", getattr(triton, "__version__", "unknown"))
except Exception as e:
    print("triton import failed:", e)
try:
    import sageattention  # noqa
    print("sageattention: OK")
except Exception as e:
    print("sageattention import failed:", e)
PY
}

gpu_sanity_check() {
    echo "---- GPU sanity check ----"
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi || true
    else
        echo "nvidia-smi not found inside container."
    fi

    python - <<'PY' || true
import torch
print("torch:", torch.__version__)
print("cuda available:", torch.cuda.is_available())
print("cuda device count:", torch.cuda.device_count())
if torch.cuda.is_available() and torch.cuda.device_count() > 0:
    print("cuda device 0:", torch.cuda.get_device_name(0))
PY
    echo "--------------------------"
}

setup_ssh() {
    mkdir -p ~/.ssh
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
            ssh-keygen -t ${type} -f "/etc/ssh/ssh_host_${type}_key" -q -N ''
            echo "${type^^} key fingerprint:"
            ssh-keygen -lf "/etc/ssh/ssh_host_${type}_key.pub"
        fi
    done

    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
    /usr/sbin/sshd
}

export_env_vars() {
    echo "Exporting environment variables..."
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"

    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"

    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^MODEL_LIST_URL=|^HF_TOKEN=|^HUGGINGFACEHUB_API_TOKEN=|^HF_WORKFLOWS_REPO=|^HF_WORKFLOWS_SUBDIR=' | while read -r line; do
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)

        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done

    # Avoid duplicate lines on repeated starts
    grep -qxF 'source /etc/rp_environment' ~/.bashrc 2>/dev/null || echo 'source /etc/rp_environment' >> ~/.bashrc
    grep -qxF 'source /etc/rp_environment' /etc/bash.bashrc 2>/dev/null || echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

auto_download_models_txt() {
    if [ -z "${MODEL_LIST_URL:-}" ]; then
        echo "MODEL_LIST_URL not set. Skipping auto model download."
        return 0
    fi

    if [ ! -d "$COMFYUI_DIR" ]; then
        echo "ComfyUI directory not found yet ($COMFYUI_DIR). Skipping model download."
        return 0
    fi

    echo "Auto-downloading models from: $MODEL_LIST_URL"
    TMP_LIST="/tmp/model_list.txt"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$MODEL_LIST_URL" -o "$TMP_LIST"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMP_LIST" "$MODEL_LIST_URL"
    else
        echo "Neither curl nor wget found. Cannot download model list."
        return 1
    fi

    COMFYUI_DIR="$COMFYUI_DIR" "$PYBIN" - << 'PY'
import os, sys, urllib.request

COMFYUI_DIR = os.environ.get("COMFYUI_DIR", "/workspace/runpod-slim/ComfyUI")
LIST_PATH = "/tmp/model_list.txt"

def ensure_dir(p: str):
    os.makedirs(p, exist_ok=True)

def safe_join(root: str, rel: str) -> str:
    rel = rel.strip().replace("\\", "/")
    rel = rel.lstrip("/")
    rel = rel.replace("..", "")
    return os.path.join(root, rel)

def download(url: str, out_path: str):
    if os.path.exists(out_path) and os.path.getsize(out_path) > 1024 * 1024:
        print(f"✓ Exists, skipping: {out_path}")
        return

    ensure_dir(os.path.dirname(out_path))
    tmp_path = out_path + ".part"

    req = urllib.request.Request(url)
    hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACEHUB_API_TOKEN")
    if hf_token and ("huggingface.co" in url or "hf.co" in url):
        req.add_header("Authorization", f"Bearer {hf_token}")

    print(f"↓ Downloading: {url}")
    with urllib.request.urlopen(req) as r, open(tmp_path, "wb") as f:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp_path, out_path)
    print(f"✓ Saved: {out_path}")

def main():
    if not os.path.exists(LIST_PATH):
        print("Model list TXT not found:", LIST_PATH)
        sys.exit(1)

    total = 0
    with open(LIST_PATH, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(maxsplit=1)
            if len(parts) != 2:
                print(f"Skipping line (expected: <url> <relative_path>): {line}")
                continue
            url, rel_path = parts[0].strip(), parts[1].strip()
            out_path = safe_join(COMFYUI_DIR, rel_path)
            download(url, out_path)
            total += 1

    print(f"Done. Processed {total} model entries.")

if __name__ == "__main__":
    main()
PY

    echo "Auto model download complete."
}

sync_hf_workflows() {
    if [ -z "${HF_WORKFLOWS_REPO:-}" ]; then
        echo "HF_WORKFLOWS_REPO not set. Skipping workflow sync."
        return 0
    fi

    if [ ! -d "$COMFYUI_DIR" ]; then
        echo "ComfyUI directory not found yet ($COMFYUI_DIR). Skipping workflow sync."
        return 0
    fi

    echo "Syncing workflows from HuggingFace repo: $HF_WORKFLOWS_REPO"

    WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"
    mkdir -p "$WORKFLOWS_DIR"

    # Ensure hub client exists (non-fatal)
    python -m pip install -U huggingface_hub >/dev/null 2>&1 || true

    # Use venv python (PYBIN) so deps are consistent
    WORKFLOWS_DIR="$WORKFLOWS_DIR" HF_WORKFLOWS_REPO="$HF_WORKFLOWS_REPO" HF_WORKFLOWS_SUBDIR="$HF_WORKFLOWS_SUBDIR" "$PYBIN" - <<'PY'
import os, shutil
from huggingface_hub import snapshot_download

repo = os.environ["HF_WORKFLOWS_REPO"]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACEHUB_API_TOKEN") or None
subdir = os.environ.get("HF_WORKFLOWS_SUBDIR","").strip().strip("/")
dst = os.environ["WORKFLOWS_DIR"]

local = snapshot_download(
    repo_id=repo,
    token=token,
    allow_patterns=["*.json", "*.JSON"],
)

src = os.path.join(local, subdir) if subdir else local
os.makedirs(dst, exist_ok=True)

count = 0
for root, _, files in os.walk(src):
    for f in files:
        if f.lower().endswith(".json"):
            shutil.copy2(os.path.join(root, f), os.path.join(dst, f))
            count += 1
            print("Synced workflow:", f)

print(f"Workflow sync done. Total: {count}")
PY

    echo "HuggingFace workflow sync complete."
}

install_custom_nodes_every_boot() {
    mkdir -p "$COMFYUI_DIR/custom_nodes"

    CUSTOM_NODES=(
        "https://github.com/ltdrdata/ComfyUI-Manager.git"
        "https://github.com/kijai/ComfyUI-KJNodes.git"
        "https://github.com/MoonGoblinDev/Civicomfy.git"
        "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect.git"
        "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
        "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
        "https://github.com/rgthree/rgthree-comfy.git"
        "https://github.com/M1kep/ComfyLiterals.git"
        "https://github.com/scofano/comfy-audio-duration.git"

        # Added custom nodes
        "https://github.com/Lightricks/ComfyUI-LTXVideo.git"
        "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
        "https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git"
        "https://github.com/WASasquatch/was-node-suite-comfyui.git"
    )

    for repo in "${CUSTOM_NODES[@]}"; do
        repo_name="$(basename "$repo" .git)"
        if [ ! -d "$COMFYUI_DIR/custom_nodes/$repo_name" ]; then
            echo "Installing custom node: $repo_name"
            cd "$COMFYUI_DIR/custom_nodes"
            git clone "$repo" "$repo_name"
        else
            echo "Custom node already present: $repo_name"
        fi
    done

    echo "Installing/refreshing custom node dependencies (best effort)..."
    cd "$COMFYUI_DIR/custom_nodes"
    for node_dir in */; do
        [ -d "$node_dir" ] || continue
        cd "$COMFYUI_DIR/custom_nodes/$node_dir"

        if [ -f "requirements.txt" ]; then
            python -m pip install --no-cache-dir -r requirements.txt || true
        fi
        if [ -f "install.py" ]; then
            python install.py || true
        fi
        if [ -f "setup.py" ]; then
            python -m pip install --no-cache-dir -e . || true
        fi
    done
}

# ---------------- Main ----------------

setup_ssh
export_env_vars

# FileBrowser init
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI + venv (one-time)
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "First time setup: Cloning ComfyUI..."
    cd /workspace/runpod-slim
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Creating venv..."
    cd "$COMFYUI_DIR"
    python3.12 -m venv --system-site-packages "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
PYBIN="$(command -v python)"

ensure_pip_tools
ensure_perf_tools

# Needed for workflow sync (best effort)
python -m pip install -U huggingface_hub >/dev/null 2>&1 || true

# Early GPU check (prints status)
gpu_sanity_check

echo "Installing/updating ComfyUI requirements..."
python -m pip install -q -r "$COMFYUI_DIR/requirements.txt" || true

# Custom nodes: check every boot (only clones missing)
install_custom_nodes_every_boot

# Auto-download after venv is active
auto_download_models_txt

# Sync workflows after venv is active
sync_hf_workflows || true

# Start ComfyUI
cd "$COMFYUI_DIR"
FIXED_ARGS="--listen 0.0.0.0 --port 8188"

CUSTOM_ARGS=""
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
fi

echo "Starting ComfyUI..."
nohup python main.py $FIXED_ARGS $CUSTOM_ARGS &> /workspace/runpod-slim/comfyui.log &

tail -f /workspace/runpod-slim/comfyui.log