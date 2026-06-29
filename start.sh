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
API_SERVER_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
mkdir -p "$HERMES_HOME/logs" "$HERMES_HOME/memory" "$HERMES_HOME/skills"

# ── Secrets ──
LLM_API_KEY="$(trim_var "${LLM_API_KEY:-}")"
LLM_MODEL="$(trim_var "${LLM_MODEL:-}")"
GATEWAY_TOKEN="$(trim_var "${GATEWAY_TOKEN:-}")"
HERMES_API_KEY="$(trim_var "${HERMES_API_KEY:-${GATEWAY_TOKEN:-}}")"

# ════════════════════════════════════════════════════════════════
# PROVIDER
# ════════════════════════════════════════════════════════════════
OPENCODE_API_BASE="${OPENCODE_API_BASE:-https://api.opencode.ai/v1}"
if [ -n "$LLM_API_KEY" ]; then
  export CUSTOM_API_KEY="$LLM_API_KEY"
  export OPENAI_API_KEY="$LLM_API_KEY"
  export OPENAI_BASE_URL="$OPENCODE_API_BASE"
  echo "[provider] OpenCode Free (base: ${OPENCODE_API_BASE})"
fi

# ════════════════════════════════════════════════════════════════
# BACKUP / RESTORE
# ════════════════════════════════════════════════════════════════
BACKUP_DATASET="${BACKUP_DATASET_NAME:-${BACKUP_DATASET:-huggingmes-backup}}"
DEVDATA_DATASET="${DEVDATA_DATASET_NAME:-huggingmes-devdata}"
HF_TOKEN="${HF_TOKEN:-}"
HF_USERNAME="${HF_USERNAME:-}"

if [ -n "${HF_TOKEN:-}" ] && [ -f "$HUGGINGMES_HOME/hermes-sync.py" ]; then
  echo "[backup] Restoring workspace from dataset..."
  python3 "$HUGGINGMES_HOME/hermes-sync.py" restore || true
  echo "[backup] Auto-creating datasets if needed..."
  python3 -c "
from huggingface_hub import HfApi
api = HfApi()
for ds in ['${BACKUP_DATASET}', '${DEVDATA_DATASET}']:
    repo_id = f'${HF_USERNAME}/{ds}' if '${HF_USERNAME}' else ds
    try:
        api.dataset_info(repo_id, token='${HF_TOKEN}')
        print(f'[backup] Dataset exists: {repo_id}')
    except:
        api.create_repo(repo_id=repo_id, repo_type='dataset', private=True, token='${HF_TOKEN}', exist_ok=True)
        print(f'[backup] Created dataset: {repo_id}')
" 2>&1 | grep -v Warning
else
  echo "[backup] HF_TOKEN not set — workspace is ephemeral"
fi

# ════════════════════════════════════════════════════════════════
# CONFIG
# ════════════════════════════════════════════════════════════════

write_hermes_env() {
  [ -z "$LLM_API_KEY" ] && return
  echo "[setup] Writing .env..."
  cat > "$HERMES_HOME/.env" << ENVEOF
LLM_API_KEY=${LLM_API_KEY}
LLM_MODEL=${LLM_MODEL}
OPENAI_API_KEY=${LLM_API_KEY}
OPENAI_BASE_URL=${OPENCODE_API_BASE}
CUSTOM_API_KEY=${LLM_API_KEY}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
GATEWAY_ALLOW_ALL_USERS=true
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_PORT=${API_SERVER_PORT}
API_SERVER_KEY=${HERMES_API_KEY}
GATEWAY_HOST=0.0.0.0
DASHBOARD_HOST=0.0.0.0
ENVEOF
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> "$HERMES_HOME/.env"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}" >> "$HERMES_HOME/.env"
  fi
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}" >> "$HERMES_HOME/.env"
    echo "DISCORD_APP_ID=${DISCORD_APP_ID:-}" >> "$HERMES_HOME/.env"
  fi
  echo "[setup] .env written."
}

# ════════════════════════════════════════════════════════════════
# SERVICES
# ════════════════════════════════════════════════════════════════

wait_for_port() {
  local host="$1" port="$2" service="$3" timeout="${4:-60}"
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
  echo "[hermes] Starting Gateway..."
  cd "$HERMES_HOME"
  if [ -f "$HERMES_HOME/.env" ]; then
    set -a; . "$HERMES_HOME/.env"; set +a
  fi
  export API_SERVER_PORT API_SERVER_HOST API_SERVER_KEY
  if command -v hermes &>/dev/null; then
    nohup hermes gateway run --accept-hooks > "$HERMES_HOME/logs/gateway.log" 2>&1 &
  else
    echo "[hermes] ERROR: CLI not found!"
    return 1
  fi
  echo "$!" > "$HERMES_HOME/gateway.pid"
  echo "[hermes] Gateway started (PID: $(cat "$HERMES_HOME/gateway.pid"))"
}

start_dashboard() {
  echo "[hermes] Starting Dashboard on :${DASHBOARD_PORT}..."
  if command -v hermes &>/dev/null; then
    nohup hermes dashboard --accept-hooks --host 0.0.0.0 --port "$DASHBOARD_PORT" --no-open \
      > "$HERMES_HOME/logs/dashboard.log" 2>&1 &
  else
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
    nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser \
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
start_gateway
start_dashboard

if hc_is_true "${DEV_MODE:-false}"; then start_jupyter
elif [ -z "${DEV_MODE:-}" ] && [ -n "${GATEWAY_TOKEN:-}" ]; then start_jupyter
fi

start_sync
start_health

sleep 10
wait_for_port "127.0.0.1" "$API_SERVER_PORT" "Gateway API" 120 || true
wait_for_port "127.0.0.1" "$DASHBOARD_PORT" "Dashboard" 30 || true

echo "[caddy] Proxy listening on :${PORT}..."
exec /usr/local/bin/caddy run --config "$HUGGINGMES_HOME/Caddyfile" --adapter caddyfile
