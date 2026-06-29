# HuggingMes AGENTS.md

## Project Overview

HuggingMes runs [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research on Hugging Face Spaces.

### Architecture
- Hermes Gateway (port 8642) — AI agent backend
- Hermes Dashboard (port 9119) — Web UI
- JupyterLab (port 8888) — Terminal access (DEV_MODE)
- Caddy (port 7860) — Reverse proxy

### Key Files
- `Dockerfile` — Multi-stage build from official Hermes image
- `start.sh` — Entrypoint that starts all services
- `Caddyfile` — Reverse proxy config
- `health-server.js` — Health endpoint for HF Spaces
- `.env.example` — All configuration options

### Deployment
- Duplicate this Space on HF Spaces
- Set LLM_API_KEY, LLM_MODEL, GATEWAY_TOKEN as secrets
- Optional: TELEGRAM_BOT_TOKEN, DISCORD_BOT_TOKEN

### Development
- Local: `docker compose up -d`
- Uses official ghcr.io/nousresearch/hermes-agent:latest
