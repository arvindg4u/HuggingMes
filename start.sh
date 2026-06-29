#!/bin/bash
set -euo pipefail

umask 0077
export TZ=Asia/Kolkata

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     🧠 HuggingMes — Hermes Agent        ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

trim_var() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
hc_is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Paths ──
HERMES_HOME="${HERMES_HOME:-/opt/data}"
HUGGINGMES_HOME="/opt/huggingmes"
PORT="${PORT:-7860}"
GATEWAY_PORT="${GATEWAY_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

mkdir -p "$HERMES_HOME/logs" "$HERMES_HOME/memory" "$HERMES_HOME/skills"

# ── Secrets ──
LLM_API_KEY="$(trim_var "${LLM_API_KEY:-}")"
LLM_MODEL="$(trim_var "${LLM_MODEL:-}")"
GATEWAY_TOKEN="$(trim_var "${GATEWAY_TOKEN:-}")"
HERMES_API_KEY="$(trim_var "${HERMES_API_KEY:-${GATEWAY_TOKEN:-}}")"

# ════════════════════════════════════════════════════════════════
# CUSTOM PROVIDER: OpenCode Free
# ════════════════════════════════════════════════════════════════
OPENCODE_API_BASE="${OPENCODE_API_BASE:-https://api.opencode.ai/v1}"
if [ -n "$LLM_API_KEY" ]; then
  export CUSTOM_API_KEY="$LLM_API_KEY"
  export OPENAI_API_KEY="$LLM_API_KEY"
  export OPENAI_BASE_URL="$OPENCODE_API_BASE"
  echo "[provider] OpenCode Free → CUSTOM_API_KEY (base: ${OPENCODE_API_BASE})"
fi

# ════════════════════════════════════════════════════════════════
# HF DATASET BACKUP
# ════════════════════════════════════════════════════════════════
BACKUP_DATASET="${BACKUP_DATASET_NAME:-${BACKUP_DATASET:-huggingmes-backup}}"
HF_TOKEN="${HF_TOKEN:-}"
HF_USERNAME="${HF_USERNAME:-}"

if [ -n "${HF_TOKEN:-}" ] && [ -f "$HUGGINGMES_HOME/hermes-sync.py" ]; then
  echo "[backup] Restoring from dataset..."
  python3 "$HUGGINGMES_HOME/hermes-sync.py" restore || true
else
  echo "[backup] HF_TOKEN not set — workspace is ephemeral"
fi

# ════════════════════════════════════════════════════════════════
# HERMES CONFIG WRITER
# ════════════════════════════════════════════════════════════════

write_hermes_env() {
  [ -z "$LLM_API_KEY" ] && return
  local env_file="$HERMES_HOME/.env"
  echo "[setup] Writing .env..."
  cat > "$env_file" << ENVEOF
LLM_API_KEY=${LLM_API_KEY}
LLM_MODEL=${LLM_MODEL}
OPENAI_API_KEY=${LLM_API_KEY}
OPENAI_BASE_URL=${OPENCODE_API_BASE}
CUSTOM_API_KEY=${LLM_API_KEY}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
GATEWAY_ALLOW_ALL_USERS=true
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_KEY=${HERMES_API_KEY}
GATEWAY_HOST=0.0.0.0
DASHBOARD_HOST=0.0.0.0
ENVEOF

  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> "$env_file"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}" >> "$env_file"
  fi
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}" >> "$env_file"
    echo "DISCORD_APP_ID=${DISCORD_APP_ID:-}" >> "$env_file"
  fi
  echo "[setup] .env written."
}

write_config_yaml() {
  local cfg="$HERMES_HOME/config.yaml"
  echo "[setup] Writing config.yaml..."
  
  # Extract model name after the provider prefix: opencode-free/deepseek-v4-flash-free → deepseek-v4-flash-free
  local model_name="${LLM_MODEL#*/}"
  [ -z "$model_name" ] && model_name="$LLM_MODEL"

  cat > "$cfg" << YAMLEOF
# Hermes Agent — HuggingMes
model:
  provider: openai
  name: ${model_name}

gateway:
  host: 0.0.0.0
  port: ${GATEWAY_PORT}
  allowed_users:
    - "*"

dashboard:
  host: 0.0.0.0
  port: ${DASHBOARD_PORT}

api_server:
  enabled: true
  host: 0.0.0.0
  key: ${HERMES_API_KEY}

memory:
  enabled: true
  dir: ${HERMES_HOME}/memory

skills:
  dir: ${HERMES_HOME}/skills

logs:
  dir: ${HERMES_HOME}/logs
  level: info

# Custom OpenAI-compatible provider config
providers:
  openai:
    base_url: ${OPENCODE_API_BASE}
    api_key: ${LLM_API_KEY}
    models:
      - id: ${model_name}
YAMLEOF
  echo "[setup] config.yaml written."
}

# ════════════════════════════════════════════════════════════════
# SERVICES
# ════════════════════════════════════════════════════════════════

wait_for_port() {
  local host="$1" port="$2" service="$3" timeout="${4:-30}"
  for i in $(seq 1 "$timeout"); do
    if curl -fsS --noproxy '*' "http://${host}:${port}" >/dev/null 2>&1; then
      echo "[wait] $service ready on $host:$port"
      return 0
    fi
    sleep 1
  done
  echo "[wait] WARNING: $service not ready after ${timeout}s"
  return 1
}

start_gateway() {
  echo "[hermes] Starting Gateway on :${GATEWAY_PORT}..."
  cd "$HERMES_HOME"
  if [ -f "$HERMES_HOME/.env" ]; then
    set -a; . "$HERMES_HOME/.env"; set +a
  fi
  if command -v hermes &>/dev/null; then
    nohup hermes gateway run --accept-hooks > "$HERMES_HOME/logs/gateway.log" 2>&1 &
  else
    echo "[hermes] ERROR: hermes CLI not found!"
    return 1
  fi
  echo "$!" > "$HERMES_HOME/gateway.pid"
  echo "[hermes] Gateway started"
}

start_dashboard() {
  echo "[hermes] Starting Dashboard on :${DASHBOARD_PORT}..."
  if command -v hermes &>/dev/null; then
    nohup hermes dashboard --accept-hooks --host 0.0.0.0 --port "$DASHBOARD_PORT" --no-open \
      > "$HERMES_HOME/logs/dashboard.log" 2>&1 &
  else
    echo "[hermes] Dashboard skipped"
    return 1
  fi
  echo "$!" > "$HERMES_HOME/dashboard.pid"
  echo "[hermes] Dashboard started"
}

start_jupyter() {
  local jtoken="${JUPYTER_TOKEN:-${GATEWAY_TOKEN:-huggingmes}}"
  echo "[jupyter] Starting JupyterLab on :${JUPYTER_PORT}..."
  mkdir -p "$HERMES_HOME/jupyter"
  if command -v jupyter-lab &>/dev/null; then
    nohup jupyter-lab \
      --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser \
      --NotebookApp.token="$jtoken" --NotebookApp.password="" \
      --NotebookApp.allow_origin='*' --NotebookApp.disable_check_xsrf=True \
      --notebook-dir="$HERMES_HOME" \
      > "$HERMES_HOME/logs/jupyter.log" 2>&1 &
    echo "[jupyter] JupyterLab started"
  fi
}

start_sync() {
  if [ -n "${HF_TOKEN:-}" ] && [ -f "$HUGGINGMES_HOME/hermes-sync.py" ]; then
    echo "[backup] Starting sync loop..."
    nohup python3 "$HUGGINGMES_HOME/hermes-sync.py" loop \
      > "$HERMES_HOME/logs/sync.log" 2>&1 &
  fi
}

start_health() {
  echo "[health] Starting health server..."
  nohup node "$HUGGINGMES_HOME/health-server.js" \
    > "$HERMES_HOME/logs/health.log" 2>&1 &
}

# ════════════════════════════════════════════════════════════════
# TELEGRAM
# ════════════════════════════════════════════════════════════════

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  export TELEGRAM_BOT_TOKEN="$(echo "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')"
  echo "[telegram] Bot configured: @Pintu_OpenClaw_bot"
  TELEGRAM_API_ROOT="${TELEGRAM_API_BASE:-}"
  if [ -n "$TELEGRAM_API_ROOT" ]; then
    export TELEGRAM_API_BASE="$TELEGRAM_API_ROOT"
  fi
  export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--dns-result-order=ipv4first"
fi

# ════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════

write_hermes_env
write_config_yaml

start_gateway
start_dashboard

if hc_is_true "${DEV_MODE:-false}"; then start_jupyter
elif [ -z "${DEV_MODE:-}" ] && [ -n "${GATEWAY_TOKEN:-}" ]; then start_jupyter
fi

start_sync
start_health

sleep 5
wait_for_port "127.0.0.1" "$GATEWAY_PORT" "Gateway" 90 || true
wait_for_port "127.0.0.1" "$DASHBOARD_PORT" "Dashboard" 30 || true

echo "[caddy] Proxy listening on :${PORT}..."
exec /usr/local/bin/caddy run --config "$HUGGINGMES_HOME/Caddyfile" --adapter caddyfile
