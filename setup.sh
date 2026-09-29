#!/usr/bin/env bash
# ============================================================================
# ainvironment — master host setup (MOCKUP)
# ----------------------------------------------------------------------------
# Thin host bootstrap for the containerized dev stack. What the OLD script
# (scripts/nanocode.sh) installed on the host now lives in containers: node,
# aws/gcloud CLIs, code-server, opencode, openchamber -> Dockerfile.
# The host only keeps:
#
#   1. NVMe storage layout
#   2. NVIDIA driver
#   3. Docker
#   4. NVIDIA Container Toolkit
#   5. cloudflared (binary + config/cloudflared/config.yml -> /etc/cloudflared)
#   6. hand-off to docker compose
#
# Status: MOCKUP. Steps print their plan; only read-only checks are real.
# Port the logic from scripts/nanocode.sh, then flip MOCK=0.
#
# SECURITY FIX vs nanocode.sh: no secrets as CLI flags (they leaked into shell
# history, the reboot-resume unit file, and `ps aux` output).
# ============================================================================

set -euo pipefail

MOCK="${MOCK:-1}"

usage() {
    cat <<'EOF'
Usage: sudo ./setup.sh -s <nvme-mount> [-v <nvidia-major>] [--no-gpu]

  -s   NVMe mount point (default /nvme0n1-disk)
  -v   NVIDIA driver major version (auto-detect, fallback 550)
  --no-gpu   skip NVIDIA driver + toolkit steps (CPU-only instance)
EOF
}

# --- mock-aware runner -----------------------------------------------------
run() {
    if [[ "${MOCK}" == "1" ]]; then
        echo "      [mock] $*"
    else
        echo "      [run ] $*"
        "$@"
    fi
}
step() { echo; echo "=== [${STEP_NO:-?}] $1 ==="; }
say() { echo "  -> $1"; }

# --- parse args ------------------------------------------------------------
NVME_MOUNT="${NVME_MOUNT:-/nvme0n1-disk}"
NVIDIA_MAJOR="${NVIDIA_MAJOR:-}"
DO_GPU=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)         NVME_MOUNT="$2"; shift 2 ;;
        -v)         NVIDIA_MAJOR="$2"; shift 2 ;;
        --no-gpu)   DO_GPU=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "run as root: sudo $0 ..." >&2
    exit 1
fi
if [[ ! -d "${NVME_MOUNT}" ]]; then
    echo "NVMe mount '${NVME_MOUNT}' does not exist" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-administrator}"
TARGET_HOME="/home/${TARGET_USER}"
WORKSPACES="${NVME_MOUNT}/workspaces"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================================
STEP_NO=1; step "NVMe storage layout"
# ----------------------------------------------------------------------------
# Port from nanocode.sh section 1:
#   mkdir ${NVME_MOUNT}/{docker,containerd,workspaces}
#   symlink /var/lib/docker      -> ${NVME_MOUNT}/docker
#   symlink /var/lib/containerd  -> ${NVME_MOUNT}/containerd
#   ln -sfn ${WORKSPACES} ~/workspaces
# Side benefit: named volumes from docker-compose.yml land on NVMe for free.
if [[ -L /var/lib/docker ]]; then
    say "/var/lib/docker already -> $(readlink /var/lib/docker)"
else
    say "relocating /var/lib/docker -> ${NVME_MOUNT}/docker"
    run mkdir -p "${NVME_MOUNT}/docker"
    # TODO: systemctl stop docker; rsync -a old -> new; ln -s
fi
if [[ -L /var/lib/containerd ]]; then
    say "/var/lib/containerd already -> $(readlink /var/lib/containerd)"
else
    say "relocating /var/lib/containerd -> ${NVME_MOUNT}/containerd"
    run mkdir -p "${NVME_MOUNT}/containerd"
    # TODO: same dance as above
fi
run mkdir -p "${WORKSPACES}"

# Pre-create the bind-mount sources from docker-compose.yml with correct
# ownership (docker would create them root-owned if missing):
home_dirs=(
    "${TARGET_HOME}/.ssh"
    "${TARGET_HOME}/.aws"
    "${TARGET_HOME}/.config/gcloud"
)
for d in "${home_dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
        run mkdir -p "$d"
        run chown "${TARGET_USER}:${TARGET_USER}" "$d"
    fi
done
if [[ ! -L "${TARGET_HOME}/workspaces" ]]; then
    run ln -sfn "${WORKSPACES}" "${TARGET_HOME}/workspaces"
fi

# ============================================================================
STEP_NO=2; step "NVIDIA driver"
# ----------------------------------------------------------------------------
if [[ "${DO_GPU}" -ne 1 ]]; then
    say "skipped (--no-gpu)"
elif nvidia-smi &>/dev/null; then
    ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    say "driver present: ${ver}"
else
    say "none — will install nvidia-driver-${NVIDIA_MAJOR:-550}"
    run apt-get update
    run apt-get install -y "nvidia-driver-${NVIDIA_MAJOR:-550}"
    # TODO: port the reboot-resume mechanism from nanocode.sh section 2, but
    # keep state in a root-only env file instead of CLI flags in the unit.
    echo "  !! TODO: reboot-resume (see scripts/nanocode.sh)"
fi

# ============================================================================
STEP_NO=3; step "Docker"
# ----------------------------------------------------------------------------
if docker info &>/dev/null; then
    say "already installed: $(docker --version)"
else
    say "installing via get.docker.com"
    run curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    run sh /tmp/get-docker.sh
fi
run usermod -aG docker "${TARGET_USER}"

# ============================================================================
STEP_NO=4; step "NVIDIA Container Toolkit"
# ----------------------------------------------------------------------------
if [[ "${DO_GPU}" -ne 1 ]]; then
    say "skipped (--no-gpu)"
elif command -v nvidia-ctk &>/dev/null; then
    say "already installed"
else
    say "installing from the NVIDIA repo"
    # TODO: port from nanocode.sh section 4 (keyring, apt list, install,
    # nvidia-ctk runtime configure --runtime=docker, GPU smoke test)
    echo "  !! TODO: implement (see scripts/nanocode.sh)"
fi

# ============================================================================
STEP_NO=5; step "cloudflared"
# ----------------------------------------------------------------------------
# Binary on the host + ingress config from this repo. Credentials stay on the
# host: either a locally-managed tunnel (tunnel create -> credentials json) or
# a token-based one whose ingress lives in the Cloudflare dashboard. If you
# run it token-based, this file is just the reference copy of the mapping.
CF_URL="https://github.com/cloudflare/cloudflared"
CF_BIN="releases/latest/download/cloudflared-linux-amd64"
if command -v cloudflared &>/dev/null; then
    say "already installed: $(cloudflared --version 2>&1 | head -1)"
else
    run wget -q "${CF_URL}/${CF_BIN}" -O /usr/local/bin/cloudflared
    run chmod +x /usr/local/bin/cloudflared
fi
cf_config="${REPO_DIR}/config/cloudflared/config.yml"
if [[ -f "${cf_config}" ]]; then
    say "deploying ingress config -> /etc/cloudflared/config.yml"
    run install -d -m 700 /etc/cloudflared
    run install -m 600 "${cf_config}" /etc/cloudflared/config.yml
else
    say "no ${cf_config} — skipped"
fi

# ============================================================================
STEP_NO=6; step "hand-off to docker compose"
# ----------------------------------------------------------------------------
if [[ ! -f "${REPO_DIR}/.env" ]]; then
    say "reminder: cp .env.example .env and fill in secrets"
fi
say "as ${TARGET_USER}: docker compose up -d --build"
run sudo -u "${TARGET_USER}" docker compose \
    -f "${REPO_DIR}/docker-compose.yml" --env-file "${REPO_DIR}/.env" up -d --build

# ============================================================================
step "summary"
# ----------------------------------------------------------------------------
cat <<EOF
  user:        ${TARGET_USER}
  nvme:        ${NVME_MOUNT}
  workspaces:  ${WORKSPACES} (-> ~/workspaces)
  services (loopback ports, mapped by cloudflared):
      code-server   127.0.0.1:8080
      opencode      127.0.0.1:4096
      openchamber   127.0.0.1:3000
EOF
echo
echo "MOCK=${MOCK} — implement the steps, then run MOCK=0."
