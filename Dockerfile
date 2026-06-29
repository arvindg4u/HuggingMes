# ════════════════════════════════════════════════════════════════
# 🧠 HuggingMes — Hermes Agent + 💻 JupyterLab Terminal
# ════════════════════════════════════════════════════════════════
# Port 7860 (exposed): Dashboard + reverse proxy
#   /           → Hermes dashboard (internal :9119)
#   /v1/        → OpenAI-compatible API (internal :8642)
#   /terminal/  → JupyterLab terminal (internal :8888)
# ════════════════════════════════════════════════════════════════

FROM ghcr.io/nousresearch/hermes-agent:latest
ARG DEV_MODE=false

# The base image runs as `hermes` user. Switch to root for system installs.
USER root

# ── Install system deps ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    jq \
    sudo \
    file \
    procps \
    nodejs \
    npm \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ── Install Caddy reverse proxy ──
RUN curl -fsSL https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_linux_amd64.tar.gz \
    -o /tmp/caddy.tar.gz && \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin/ caddy && \
    chmod +x /usr/local/bin/caddy && \
    rm /tmp/caddy.tar.gz

# ── Install JupyterLab + HF tools (DEV_MODE) ──
RUN if [ "${DEV_MODE}" = "true" ] || [ "${DEV_MODE}" = "1" ]; then \
      pip3 install --no-cache-dir --break-system-packages \
        jupyterlab==4.5.7 \
        notebook==7.3.3 \
        tornado==6.5.5 \
        ipywidgets==8.1.8 \
        huggingface_hub hf_transfer; \
    else \
      pip3 install --no-cache-dir --break-system-packages \
        huggingface_hub hf_transfer; \
    fi

# ── Sudo for the runtime user ──
RUN printf '%s\n' \
      'Cmnd_Alias HERMES_APT = /usr/bin/apt, /usr/bin/apt-get, /usr/bin/dpkg' \
      'hermes ALL=(root) NOPASSWD: HERMES_APT' \
      > /etc/sudoers.d/hermes-apt && \
    chmod 0440 /etc/sudoers.d/hermes-apt && \
    visudo -cf /etc/sudoers.d/hermes-apt

# ── Place our app files ──
RUN mkdir -p /opt/huggingmes && chown hermes:hermes /opt/huggingmes
COPY --chown=hermes:hermes start.sh /opt/huggingmes/start.sh
COPY --chown=hermes:hermes Caddyfile /opt/huggingmes/Caddyfile
COPY --chown=hermes:hermes health-server.js /opt/huggingmes/health-server.js
RUN chmod +x /opt/huggingmes/start.sh

# ── Override entrypoint / CMD ──
# The base image uses s6-overlay (/init) as PID 1. We replace it with
# our own start.sh because we need gateway + dashboard + caddy + jupyter
# all in one container (HF Space single-process model).
ENTRYPOINT []
CMD ["/opt/huggingmes/start.sh"]

# ── Switch back to non-root user ──
USER hermes

# ── HF Space port ──
EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s \
  CMD curl -fsS --noproxy '*' http://localhost:7860/health || exit 1
