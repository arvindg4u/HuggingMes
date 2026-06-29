# ════════════════════════════════════════════════════════════════
# 🧠 HuggingMes — Hermes Agent on HF Spaces
# ════════════════════════════════════════════════════════════════
FROM python:3.13-slim
ARG DEV_MODE=false

# ── System deps ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq git sudo procps nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# ── Caddy reverse proxy ──
RUN curl -fsSL https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_linux_amd64.tar.gz \
    -o /tmp/caddy.tar.gz && \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin/ caddy && \
    chmod +x /usr/local/bin/caddy && rm /tmp/caddy.tar.gz

# ── Install Hermes Agent from PyPI ──
# python:3.13-slim doesn't have PEP 668 marker, so --break-system-packages not needed
RUN pip install --no-cache-dir hermes-agent && \
    hermes --version

# ── Install JupyterLab + HF tools (DEV_MODE) ──
RUN if [ "${DEV_MODE}" = "true" ] || [ "${DEV_MODE}" = "1" ]; then \
      pip install --no-cache-dir \
        jupyterlab==4.5.7 notebook==7.3.3 tornado==6.5.5 ipywidgets==8.1.8 \
        huggingface_hub; \
    else \
      pip install --no-cache-dir huggingface_hub; \
    fi

# ── App files ──
RUN mkdir -p /opt/huggingmes
COPY start.sh /opt/huggingmes/start.sh
COPY Caddyfile /opt/huggingmes/Caddyfile
COPY health-server.js /opt/huggingmes/health-server.js
COPY hermes-sync.py /opt/huggingmes/hermes-sync.py
RUN chmod +x /opt/huggingmes/start.sh /opt/huggingmes/hermes-sync.py

ENV PYTHONUNBUFFERED=1 \
    HERMES_HOME=/opt/data

WORKDIR /opt/huggingmes
EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD curl -fsS --noproxy '*' http://localhost:7860/health || exit 1

CMD ["/opt/huggingmes/start.sh"]
