#!/bin/bash

# ==========================================================
# Dev Environment Setup Script
# Sets up a cloud GPU instance: NVMe storage layout, NVIDIA
# drivers, Docker, Container Toolkit, AWS CLI, gcloud CLI,
# code-server, Cloudflare.
# ==========================================================

usage() {
    echo "Usage: sudo bash $0 -p <password> -t <tunnel-token> -s <nvme-mount>"
    echo ""
    echo "Options:"
    echo "  -p  code-server password (required)"
    echo "  -t  Cloudflare Tunnel token (required)"
    echo "  -s  NVMe mount point (required, e.g. /nvme0n1-disk)"
    echo "  -v  NVIDIA driver version (default: auto-detect)"
    exit 1
}

NVIDIA_DRIVER_VERSION=""

while getopts "p:t:s:v:" opt; do
    case ${opt} in
        p ) CS_PASSWORD=$OPTARG ;;
        t ) TUNNEL_TOKEN=$OPTARG ;;
        s ) NVME_MOUNT=$OPTARG ;;
        v ) NVIDIA_DRIVER_VERSION=$OPTARG ;;
        \? ) usage ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (sudo bash $0 ...)"
    exit 1
fi

if [ -z "$CS_PASSWORD" ] || [ -z "$TUNNEL_TOKEN" ] || [ -z "$NVME_MOUNT" ]; then
    echo "Error: Missing required arguments."
    usage
fi

if [ ! -d "$NVME_MOUNT" ]; then
    echo "Error: NVMe mount '$NVME_MOUNT' does not exist."
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="/home/$TARGET_USER"
WORKSPACES="${NVME_MOUNT}/workspaces"

# ==========================================
# 1. NVMe Storage Layout
# ==========================================
echo "--- [1/11] NVMe storage layout ($NVME_MOUNT) ---"

# /nvme/workspaces  — code, repos
# /nvme/docker      — images, layers, volumes
# /nvme/containerd  — snapshots

NVME_DOCKER="${NVME_MOUNT}/docker"
NVME_CONTAINERD="${NVME_MOUNT}/containerd"

for dir in "$NVME_DOCKER" "$NVME_CONTAINERD" "$WORKSPACES"; do
    mkdir -p "$dir"
done
chown "$TARGET_USER:$TARGET_USER" "$WORKSPACES"

symlink_data_dir() {
    local src="$1"
    local dest="$2"
    local service="$3"
    if [ -L "$src" ]; then
        echo "$src already symlinked, skipping."
        return
    fi
    echo "Pointing $src -> $dest"
    systemctl stop "$service" 2>/dev/null || true
    if [ -d "$src" ]; then
        rsync -a "$src/" "$dest/"
        rm -rf "$src"
    fi
    ln -s "$dest" "$src"
}

symlink_data_dir /var/lib/docker "$NVME_DOCKER" docker
symlink_data_dir /var/lib/containerd "$NVME_CONTAINERD" containerd

if [ ! -L "${TARGET_HOME}/workspaces" ]; then
    ln -sfn "$WORKSPACES" "${TARGET_HOME}/workspaces"
    echo "Linked ~/workspaces -> $WORKSPACES"
fi

echo "NVMe layout:"
echo "  $NVME_DOCKER     -> /var/lib/docker"
echo "  $NVME_CONTAINERD -> /var/lib/containerd"
echo "  $WORKSPACES      -> ~/workspaces"

# ==========================================
# 2. NVIDIA Drivers
# ==========================================
echo "--- [2/11] NVIDIA Drivers ---"

if nvidia-smi &>/dev/null; then
    CURRENT=$(
        nvidia-smi --query-gpu=driver_version \
            --format=csv,noheader | head -1
    )
    echo "NVIDIA driver $CURRENT already installed."
    if [ -n "$NVIDIA_DRIVER_VERSION" ] \
        && [ "${CURRENT%%.*}" != "$NVIDIA_DRIVER_VERSION" ]; then
        echo "Requested $NVIDIA_DRIVER_VERSION, reinstalling..."
        apt-get purge -y 'nvidia-*' && apt-get autoremove -y
        apt-get update \
            && apt-get install -y \
                "nvidia-driver-${NVIDIA_DRIVER_VERSION}"
    fi
else
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-550}"
    echo "No driver detected. Installing $NVIDIA_DRIVER_VERSION..."
    apt-get update \
        && apt-get install -y \
            "nvidia-driver-${NVIDIA_DRIVER_VERSION}"
fi

echo "Verifying NVIDIA driver..."
if ! nvidia-smi &>/dev/null; then
    echo ""
    echo "=========================================="
    echo "  Driver installed but kernel module not loaded."
    echo "  Scheduling auto-resume and rebooting in 10s..."
    echo "=========================================="
    RESUME_UNIT="/etc/systemd/system/cnvx-resume.service"
    SCRIPT_PATH="$(readlink -f "$0")"
    cat <<EOF > "$RESUME_UNIT"
[Unit]
Description=Resume cnvx setup after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_PATH} \\
    -p ${CS_PASSWORD} \\
    -t ${TUNNEL_TOKEN} \\
    -s ${NVME_MOUNT}
ExecStartPost=/bin/systemctl disable cnvx-resume.service
ExecStartPost=/bin/rm -f ${RESUME_UNIT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 600 "$RESUME_UNIT"
    systemctl daemon-reload
    systemctl enable cnvx-resume.service
    sleep 10
    reboot
    exit 0
fi

# ==========================================
# 3. Docker
# ==========================================
echo "--- [3/11] Docker ---"

if command -v docker &>/dev/null; then
    echo "Docker already installed, skipping."
else
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$TARGET_USER"
fi

systemctl start containerd docker

# ==========================================
# 4. NVIDIA Container Toolkit
# ==========================================
echo "--- [4/11] NVIDIA Container Toolkit ---"

KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
NVIDIA_CTK_LIST="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
NVIDIA_CTK_REPO="https://nvidia.github.io/libnvidia-container"

rm -f "$NVIDIA_CTK_LIST"
curl -fsSL "${NVIDIA_CTK_REPO}/gpgkey" \
    | gpg --dearmor --yes -o "$KEYRING"
echo "deb [signed-by=${KEYRING}]" \
    "${NVIDIA_CTK_REPO}/stable/deb/\$(ARCH) /" \
    | tee "$NVIDIA_CTK_LIST"

if command -v nvidia-ctk &>/dev/null; then
    echo "NVIDIA Container Toolkit already installed."
else
    echo "Installing NVIDIA Container Toolkit..."
    apt-get update \
        && apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi

echo "Verifying GPU access in Docker..."
CUDA_TEST="nvidia/cuda:12.0.0-base-ubuntu22.04"
if ! docker run --rm --gpus all "$CUDA_TEST" nvidia-smi; then
    echo "WARNING: Docker GPU test failed."
fi

# ==========================================
# 5. AWS CLI v2
# ==========================================
echo "--- [5/11] AWS CLI ---"

if command -v aws &>/dev/null; then
    echo "AWS CLI already installed ($(aws --version 2>&1)), skipping."
else
    echo "Installing AWS CLI v2..."
    apt-get install -y unzip
    AWS_TMP=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "${AWS_TMP}/aws.zip"
    unzip -q "${AWS_TMP}/aws.zip" -d "$AWS_TMP"
    "${AWS_TMP}/aws/install" --update
    rm -rf "$AWS_TMP"
fi

# ==========================================
# 6. gcloud CLI
# ==========================================
echo "--- [6/11] gcloud CLI ---"

if command -v gcloud &>/dev/null; then
    echo "gcloud CLI already installed ($(gcloud --version | head -1)), skipping."
else
    echo "Installing gcloud CLI..."
    GCLOUD_KEYRING="/usr/share/keyrings/cloud.google.gpg"
    GCLOUD_LIST="/etc/apt/sources.list.d/google-cloud-sdk.list"
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor --yes -o "$GCLOUD_KEYRING"
    echo "deb [signed-by=${GCLOUD_KEYRING}]" \
        "https://packages.cloud.google.com/apt cloud-sdk main" \
        | tee "$GCLOUD_LIST"
    apt-get update \
        && apt-get install -y google-cloud-cli
fi

# ==========================================
# 7. code-server
# ==========================================
echo "--- [7/11] code-server ---"

if command -v code-server &>/dev/null; then
    echo "code-server already installed, skipping."
else
    echo "Installing code-server..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi

echo "Configuring code-server..."
CS_CONFIG_DIR="${TARGET_HOME}/.config/code-server"
CS_DATA_DIR="${NVME_MOUNT}/code-server"
mkdir -p "$CS_CONFIG_DIR" "$CS_DATA_DIR"
chown "$TARGET_USER:$TARGET_USER" "$CS_DATA_DIR"
cat <<EOF > "$CS_CONFIG_DIR/config.yaml"
bind-addr: 127.0.0.1:8080
auth: password
password: ${CS_PASSWORD}
cert: false
user-data-dir: ${CS_DATA_DIR}
app-name: cnvx-dev
EOF
chown -R "$TARGET_USER:$TARGET_USER" "${TARGET_HOME}/.config"

CS_OVERRIDE="/etc/systemd/system/code-server@${TARGET_USER}.service.d"
mkdir -p "$CS_OVERRIDE"
cat <<EOF > "$CS_OVERRIDE/default-dir.conf"
[Service]
ExecStart=
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080 ${WORKSPACES}
EOF

systemctl daemon-reload
systemctl enable --now "code-server@${TARGET_USER}"

# ==========================================
# 8. Node.js + npm (LTS via NodeSource)
# ==========================================
echo "--- [8/11] Node.js + npm ---"

if command -v npm &>/dev/null; then
    echo "npm already installed ($(npm --version)), skipping."
else
    echo "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi

# ==========================================
# 9. Gemini CLI (npm global)
# ==========================================
echo "--- [9/11] Gemini CLI ---"

if command -v gemini &>/dev/null; then
    echo "gemini-cli already installed ($(gemini --version 2>&1)), skipping."
else
    # Pinned to 0.39.1 — 0.40.0 has a bug where A2AClientManager always
    # constructs a ProxyAgent and crashes at startup when no proxy URL is
    # configured ("Invalid URL protocol"). Bump cautiously.
    echo "Installing @google/gemini-cli@0.39.1 globally..."
    npm install -g @google/gemini-cli@0.39.1
fi

# gemini-cli has three shell-side issues we work around with one alias:
#   1. VSCODE_PROXY_URI (injected by VS Code Remote) contains a `{{port}}`
#      template placeholder that crashes undici's URL parser → strip it.
#   2. A2AClientManager unconditionally builds a ProxyAgent at startup; with no
#      proxy URL set, undici errors with "Invalid URL protocol" → set a dummy
#      HTTP_PROXY / HTTPS_PROXY URL to satisfy the constructor.
#   3. The dummy proxy would also be used for OAuth + Google API calls and fail
#      with ECONNREFUSED → set NO_PROXY for the relevant Google domains so the
#      fetch path bypasses the proxy and goes direct.
TARGET_BASHRC="${TARGET_HOME}/.bashrc"
if ! grep -q "^gemini()" "$TARGET_BASHRC" 2>/dev/null; then
    cat >> "$TARGET_BASHRC" <<'EOF'

# gemini-cli wrapper: strip VSCODE_PROXY_URI, set dummy HTTP(S)_PROXY to satisfy
# A2AClientManager's unconditional ProxyAgent construction, and NO_PROXY for
# the real Google domains so OAuth + API calls go direct.
gemini() {
    local _np="oauth2.googleapis.com,codeassist.google.com"
    _np="$_np,generativelanguage.googleapis.com,accounts.google.com"
    _np="$_np,*.googleapis.com,*.google.com"
    env -u VSCODE_PROXY_URI \
        HTTP_PROXY=http://127.0.0.1:9999 \
        HTTPS_PROXY=http://127.0.0.1:9999 \
        NO_PROXY="$_np" \
        command gemini "$@"
}
EOF
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_BASHRC"
fi

# ==========================================
# 10. Cloudflared
# ==========================================
echo "--- [10/11] Cloudflared ---"

if command -v cloudflared &>/dev/null; then
    echo "Cloudflared already installed, skipping install."
else
    echo "Installing Cloudflared..."
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared"
    CLOUDFLARED_BIN="releases/latest/download/cloudflared-linux-amd64"
    wget -q "${CLOUDFLARED_URL}/${CLOUDFLARED_BIN}" \
        -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

cloudflared service uninstall 2>/dev/null || true
cloudflared service install "$TUNNEL_TOKEN"

# ==========================================
# 9. Misc CLI tools
# ==========================================
echo "--- [11/11] Misc CLI tools ---"

# grc — generic colourizer used by `./deploy/deploy.sh tail` for the trader log.
if command -v grc &>/dev/null; then
    echo "grc already installed, skipping."
else
    echo "Installing grc..."
    apt-get install -y grc
fi

# ==========================================
# Final restarts
# ==========================================
echo "--- Restarting services ---"
systemctl daemon-reload
systemctl restart "code-server@${TARGET_USER}"
systemctl restart cloudflared

echo ""
echo "=========================================="
echo "  SETUP COMPLETE"
echo "=========================================="
echo "  User:           $TARGET_USER"
echo "  NVIDIA Driver:  $(nvidia-smi --query-gpu=driver_version \
    --format=csv,noheader | head -1)"
echo "  NVMe:           $NVME_MOUNT"
echo "  Workspaces:     $WORKSPACES"
echo "  Docker:         $NVME_DOCKER"
echo "  Containerd:     $NVME_CONTAINERD"
echo "  code-server:    127.0.0.1:8080"
echo "  Cloudflared:    running"
echo "=========================================="
