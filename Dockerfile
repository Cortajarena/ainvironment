# ============================================================
# ainvironment — the one shared dev image
#
# Started three ways by docker-compose.yml (code-server,
# opencode serve, openchamber serve) — only command and port
# differ. No gemini, on purpose.
# ============================================================

FROM ubuntu:24.04

# NOTE: DEV_UID/DEV_GID, not UID/GID — the build shell is dash, which does
# not set $UID, so a bare UID arg would expand empty inside RUN.
ARG USERNAME=dev
ARG DEV_UID=1000
ARG DEV_GID=1000
ARG NODE_MAJOR=26

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ---- system packages -------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg sudo unzip wget \
        openssh-client rsync less vim jq bash-completion \
    && rm -rf /var/lib/apt/lists/*

# ---- non-root user ----------------------------------------------------
RUN groupadd --gid "${DEV_GID}" "${USERNAME}" \
    && useradd --uid "${DEV_UID}" --gid "${DEV_GID}" --create-home \
        --shell /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" \
        > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

# ---- Node.js (latest major, via NodeSource) ----------------------------
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- AWS CLI v2 --------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) aws_arch="x86_64" ;; \
        arm64) aws_arch="aarch64" ;; \
        *) echo "unsupported arch"; exit 1 ;; \
    esac; \
    aws_zip="awscli-exe-linux-${aws_arch}.zip"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL "https://awscli.amazonaws.com/${aws_zip}" \
        -o "${tmp}/aws.zip"; \
    unzip -q "${tmp}/aws.zip" -d "${tmp}"; \
    "${tmp}/aws/install"; \
    rm -rf "${tmp}"

# ---- gcloud CLI --------------------------------------------------------
RUN keyring=/usr/share/keyrings/cloud.google.gpg; \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o "${keyring}" \
    && echo "deb [signed-by=${keyring}]" \
        "https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# ---- code-server --------------------------------------------------------
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ---- opencode v2 (standalone installer) -------------------------------
# NOTE: npm's opencode-ai package is still v1 — v2 only ships via the
# official installer (lands in $HOME/.opencode/bin).
USER ${USERNAME}
WORKDIR /home/${USERNAME}
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
ENV PATH="/home/${USERNAME}/.opencode/bin:${PATH}"

# ---- openchamber --------------------------------------------------------
USER root
RUN npm install -g @openchamber/web@latest
USER ${USERNAME}

# ---- mount-point dirs for named volumes -------------------------------
# Pre-create owned by dev so fresh named volumes inherit dev:dev instead
# of root:root.
RUN set -eux; \
    for d in .local/share/opencode .local/share/code-server \
             .config/opencode .config/openchamber .aws .config/gcloud; do \
        mkdir -p "/home/${USERNAME}/${d}"; \
    done; \
    chown -R "${DEV_UID}:${DEV_GID}" \
        "/home/${USERNAME}/.local" \
        "/home/${USERNAME}/.config" \
        "/home/${USERNAME}/.opencode"

WORKDIR /home/${USERNAME}/workspaces

CMD ["bash"]
