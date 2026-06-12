#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# One-click startup: bootstrap → server → web UI (Vite dev server)
#
# Usage:
#   scripts/start-web-ui.sh
#   scripts/start-web-ui.sh --host 0.0.0.0    # bind to all interfaces
#
# Environment overrides:
#   SERVER_PORT=3456   preferred backend port
#   WEB_PORT=2024      preferred Web UI port
#   HOST=127.0.0.1     bind host for both processes
#   CONNECT_HOST=      URL host for browser (defaults to HOST; use 127.0.0.1 when HOST=0.0.0.0)
#   LOG_DIR=/tmp/...   directory for server.log and web.log
#   SKIP_BOOTSTRAP=1   skip dependency bootstrap
#   SKIP_LITELLM=1     skip LiteLLM proxy startup
#   VLLM_PORT=18000    vLLM server port
#   LITELLM_PORT=4000  LiteLLM proxy port
#
# The script checks the preferred ports first and scans upward when busy.
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${ROOT_DIR}/desktop"
HOST="${HOST:-127.0.0.1}"
# CONNECT_HOST: the address the browser uses to reach the server.
# When binding to 0.0.0.0 (all interfaces), the browser cannot connect to 0.0.0.0,
# so we default CONNECT_HOST to 127.0.0.1 (works for local/SSH-forwarded access).
CONNECT_HOST="${CONNECT_HOST:-${HOST}}"
if [[ "${CONNECT_HOST}" == "0.0.0.0" ]]; then
  CONNECT_HOST="127.0.0.1"
fi
SERVER_PORT_START="${SERVER_PORT:-3456}"
WEB_PORT_START="${WEB_PORT:-2024}"
MAX_PORT_SCAN="${MAX_PORT_SCAN:-100}"
RUN_ID="$(date +%s)-$RANDOM"
LOG_DIR="${LOG_DIR:-/tmp/cc-hust-web-ui-${RUN_ID}}"
SERVER_LOG="${LOG_DIR}/server.log"
WEB_LOG="${LOG_DIR}/web.log"

# Parse --host from args
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^# ─/p' "$0" | head -20; exit 0 ;;
    *)
      EXTRA_ARGS+=("$1"); shift ;;
  esac
done

SERVER_PID=""
WEB_PID=""

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[web-ui]${NC} $*"; }
ok()    { echo -e "${GREEN}[web-ui]${NC} $*"; }
warn()  { echo -e "${YELLOW}[web-ui]${NC} $*"; }
err()   { echo -e "${RED}[web-ui]${NC} $*" >&2; }

# ── Port checking — works without lsof/nc ──
is_port_in_use() {
  local port="$1"

  # Method 1: ss (most Linux systems)
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    return 1
  fi

  # Method 2: lsof
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  # Method 3: netcat
  if command -v nc >/dev/null 2>&1; then
    nc -z "${HOST}" "${port}" >/dev/null 2>&1
    return $?
  fi

  # Method 4: bash built-in /dev/tcp
  if (echo >/dev/tcp/"${HOST}"/"${port}") >/dev/null 2>&1; then
    return 0
  fi

  # Method 5: curl (works for HTTP servers)
  if curl -sf --max-time 1 "http://${HOST}:${port}/" >/dev/null 2>&1; then
    return 0
  fi

  # No method available — assume port is free
  return 1
}

find_available_port() {
  local start_port="$1"
  local port="${start_port}"
  local end_port=$((start_port + MAX_PORT_SCAN))

  while (( port <= end_port )); do
    if ! is_port_in_use "${port}"; then
      printf '%s\n' "${port}"
      return 0
    fi
    port=$((port + 1))
  done

  err "No available port found in range ${start_port}-${end_port}"
  exit 1
}

urlencode() {
  bun -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

wait_for_http() {
  local url="$1"
  local log_file="$2"
  local label="$3"

  info "Waiting for ${label} at ${url}..."
  for _ in $(seq 1 120); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ -n "${SERVER_PID}" ]] && ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
      err "${label} process exited before ${url} became ready. Recent log:"
      tail -n 40 "${SERVER_LOG}" >&2 || true
      exit 1
    fi

    if [[ -n "${WEB_PID}" ]] && ! kill -0 "${WEB_PID}" >/dev/null 2>&1; then
      err "${label} process exited before ${url} became ready. Recent log:"
      tail -n 40 "${WEB_LOG}" >&2 || true
      exit 1
    fi

    sleep 1
  done

  err "Timed out waiting for ${url}. Recent log:"
  tail -n 40 "${log_file}" >&2 || true
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ -n "${WEB_PID}" ]]; then
    kill "${WEB_PID}" >/dev/null 2>&1 || true
    wait "${WEB_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" >/dev/null 2>&1 || true
  fi

  if [[ "${exit_code}" -ne 0 && "${exit_code}" -ne 130 && "${exit_code}" -ne 143 ]]; then
    echo "Logs kept at ${LOG_DIR}" >&2
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Prerequisites ──
require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}

require_command bun
require_command curl

if [[ ! -d "${DESKTOP_DIR}" ]]; then
  err "Desktop directory not found: ${DESKTOP_DIR}"
  exit 1
fi

# ── Bootstrap (auto-install deps + fix symlinks) ──
if [[ "${SKIP_BOOTSTRAP:-0}" != "1" ]]; then
  info "Running bootstrap..."
  BOOTSTRAP_QUIET=1 bash "${ROOT_DIR}/bin/bootstrap.sh" || {
    err "Bootstrap failed. Run manually: ./bin/bootstrap.sh"
    exit 1
  }
fi

# ── vLLM + LiteLLM proxy ──
VLLM_PORT="${VLLM_PORT:-18000}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_CONFIG="${LITELLM_CONFIG:-${ROOT_DIR}/litellm_config_vllm.yaml}"
LITELLM_LOG="${LITELLM_LOG:-/tmp/litellm_vllm.log}"
LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm 2>/dev/null || echo "$HOME/miniconda3/bin/litellm")}"
LITELLM_STARTUP_WAIT="${LITELLM_STARTUP_WAIT:-30}"

if [[ "${SKIP_LITELLM:-0}" != "1" ]]; then
  # Check vLLM
  if curl -sf --max-time 5 "http://localhost:${VLLM_PORT}/v1/models" > /dev/null 2>&1; then
    ok "vLLM reachable on port ${VLLM_PORT}"
  else
    warn "vLLM not reachable on port ${VLLM_PORT}. LiteLLM will start but may not work until vLLM is up."
  fi

  # Start LiteLLM if not running
  is_litellm_running() {
    curl -sf --max-time 3 "http://localhost:${LITELLM_PORT}/v1/models" > /dev/null 2>&1
  }

  if is_litellm_running; then
    ok "LiteLLM proxy already running on port ${LITELLM_PORT}"
  else
    info "Starting LiteLLM proxy on port ${LITELLM_PORT}..."
    if [[ ! -f "$LITELLM_CONFIG" ]]; then
      warn "LiteLLM config not found: $LITELLM_CONFIG — skipping proxy"
    elif ! command -v "$LITELLM_BIN" &>/dev/null && [[ ! -x "$LITELLM_BIN" ]]; then
      warn "litellm not found — install with: pip install 'litellm[proxy]'"
    else
      nohup "$LITELLM_BIN" --config "$LITELLM_CONFIG" --port "$LITELLM_PORT" \
        > "$LITELLM_LOG" 2>&1 &
      LITELLM_PID=$!
      for i in $(seq 1 "$LITELLM_STARTUP_WAIT"); do
        if is_litellm_running; then
          ok "LiteLLM proxy ready on port ${LITELLM_PORT} (took ${i}s)"
          break
        fi
        if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
          err "LiteLLM process died. Check log: $LITELLM_LOG"
          break
        fi
        sleep 1
      done
      is_litellm_running || warn "LiteLLM not ready — backend may fail to reach vLLM"
    fi
  fi
fi

# ── Find available ports ──
mkdir -p "${LOG_DIR}"

SERVER_PORT_RESOLVED="$(find_available_port "${SERVER_PORT_START}")"
WEB_PORT_RESOLVED="$(find_available_port "${WEB_PORT_START}")"
if [[ "${WEB_PORT_RESOLVED}" == "${SERVER_PORT_RESOLVED}" ]]; then
  WEB_PORT_RESOLVED="$(find_available_port "$((WEB_PORT_RESOLVED + 1))")"
fi

SERVER_URL="http://${CONNECT_HOST}:${SERVER_PORT_RESOLVED}"
WEB_URL="http://${CONNECT_HOST}:${WEB_PORT_RESOLVED}/?serverUrl=$(urlencode "${SERVER_URL}")"

if [[ "${SERVER_PORT_RESOLVED}" != "${SERVER_PORT_START}" ]]; then
  warn "Server port ${SERVER_PORT_START} is busy; using ${SERVER_PORT_RESOLVED}."
fi

if [[ "${WEB_PORT_RESOLVED}" != "${WEB_PORT_START}" ]]; then
  warn "Web UI port ${WEB_PORT_START} is busy; using ${WEB_PORT_RESOLVED}."
fi

# ── Start backend server ──
info "Starting backend server on port ${SERVER_PORT_RESOLVED}..."
(
  cd "${ROOT_DIR}"
  SERVER_PORT="${SERVER_PORT_RESOLVED}" bun run src/server/index.ts \
    --host "${HOST}" --port "${SERVER_PORT_RESOLVED}"
) >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

wait_for_http "http://127.0.0.1:${SERVER_PORT_RESOLVED}/health" "${SERVER_LOG}" "Backend server"
ok "Backend server ready: ${SERVER_URL}"

# ── Start Vite web UI ──
info "Starting Web UI dev server on port ${WEB_PORT_RESOLVED}..."
(
  cd "${DESKTOP_DIR}"
  VITE_DESKTOP_SERVER_URL="${SERVER_URL}" bun run dev -- \
    --host "${HOST}" --port "${WEB_PORT_RESOLVED}" --strictPort
) >"${WEB_LOG}" 2>&1 &
WEB_PID=$!

wait_for_http "http://127.0.0.1:${WEB_PORT_RESOLVED}" "${WEB_LOG}" "Web UI"
ok "Web UI ready: http://${HOST}:${WEB_PORT_RESOLVED}"

# ── Summary ──
cat <<EOF

${GREEN}═══════════════════════════════════════════════════${NC}
  ${GREEN}claude-code-hust Web UI is ready${NC}
${GREEN}═══════════════════════════════════════════════════${NC}

  Web UI:    ${CYAN}${WEB_URL}${NC}
  Backend:   ${CYAN}${SERVER_URL}${NC}
  Logs:      ${LOG_DIR}/

Press Ctrl-C to stop both processes.
EOF

# ── Keep alive ──
while true; do
  if ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    err "Backend server exited unexpectedly"
    wait "${SERVER_PID}"
    exit $?
  fi

  if ! kill -0 "${WEB_PID}" >/dev/null 2>&1; then
    err "Web UI exited unexpectedly"
    wait "${WEB_PID}"
    exit $?
  fi

  sleep 1
done
