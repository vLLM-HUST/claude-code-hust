#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# One-click startup: bootstrap → LiteLLM proxy → vLLM → claude-code-hust CLI
#
# Usage:
#   ./bin/start-local.sh              # interactive TUI
#   ./bin/start-local.sh -p "prompt"  # one-shot print mode
#   ./bin/start-local.sh --help       # pass any cli flags through
#
# Prerequisites (already running):
#   vLLM server on port 18000 (Qwen3-32B)
#
# What this script does:
#   0. Bootstraps dependencies (installs, fixes symlinks)
#   1. Verifies vLLM is reachable
#   2. Starts LiteLLM proxy (port 4000) if not running
#   3. Waits for proxy to be healthy
#   4. Launches claude-code-hust
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[start-local]${NC} $*"; }
ok()    { echo -e "${GREEN}[start-local]${NC} $*"; }
warn()  { echo -e "${YELLOW}[start-local]${NC} $*"; }
err()   { echo -e "${RED}[start-local]${NC} $*" >&2; }

# ── Step 0: Bootstrap (auto-install deps + fix symlinks) ──
if [[ "${SKIP_BOOTSTRAP:-0}" != "1" ]]; then
  BOOTSTRAP_QUIET=1 bash "${ROOT_DIR}/bin/bootstrap.sh" || {
    err "Bootstrap failed. Run manually: ./bin/bootstrap.sh"
    exit 1
  }
fi

# ── Config (override via env) ──
VLLM_PORT="${VLLM_PORT:-18000}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_CONFIG="${LITELLM_CONFIG:-litellm_config_vllm.yaml}"
LITELLM_LOG="${LITELLM_LOG:-/tmp/litellm_vllm.log}"
LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm 2>/dev/null || echo "$HOME/miniconda3/bin/litellm")}"
VLLM_PROBE_TIMEOUT="${VLLM_PROBE_TIMEOUT:-5}"
LITELLM_STARTUP_WAIT="${LITELLM_STARTUP_WAIT:-30}"

# ── Step 1: Check vLLM ──
info "Checking vLLM on port ${VLLM_PORT}..."
if curl -sf --max-time "$VLLM_PROBE_TIMEOUT" "http://localhost:${VLLM_PORT}/v1/models" > /dev/null 2>&1; then
  MODEL_NAME=$(curl -sf --max-time "$VLLM_PROBE_TIMEOUT" "http://localhost:${VLLM_PORT}/v1/models" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
  ok "vLLM reachable — model: ${MODEL_NAME}"
else
  err "vLLM not reachable on http://localhost:${VLLM_PORT}"
  err "Start vLLM first, e.g.:"
  err "  vllm-hust serve /data/shared-models/Qwen3-32B --served-model-name Qwen3-32B \\"
  err "    --port ${VLLM_PORT} --tensor-parallel-size 2 --max-model-len 32768 \\"
  err "    --enable-auto-tool-choice --tool-call-parser hermes"
  exit 1
fi

# ── Step 2: Start LiteLLM proxy (if not running) ──
is_litellm_running() {
  curl -sf --max-time 3 "http://localhost:${LITELLM_PORT}/v1/models" > /dev/null 2>&1
}

if is_litellm_running; then
  ok "LiteLLM proxy already running on port ${LITELLM_PORT}"
else
  info "Starting LiteLLM proxy on port ${LITELLM_PORT}..."
  if [[ ! -x "$LITELLM_BIN" ]] && ! command -v "$LITELLM_BIN" &>/dev/null; then
    err "litellm not found at: $LITELLM_BIN"
    err "Install: pip install 'litellm[proxy]'"
    exit 1
  fi
  if [[ ! -f "$LITELLM_CONFIG" ]]; then
    err "LiteLLM config not found: $LITELLM_CONFIG"
    exit 1
  fi

  nohup "$LITELLM_BIN" --config "$LITELLM_CONFIG" --port "$LITELLM_PORT" \
    > "$LITELLM_LOG" 2>&1 &
  LITELLM_PID=$!

  # Wait for proxy to become healthy
  info "Waiting for LiteLLM to be ready (PID ${LITELLM_PID})..."
  for i in $(seq 1 "$LITELLM_STARTUP_WAIT"); do
    if is_litellm_running; then
      ok "LiteLLM proxy ready on port ${LITELLM_PORT} (took ${i}s)"
      break
    fi
    if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
      err "LiteLLM process died. Check log: $LITELLM_LOG"
      tail -20 "$LITELLM_LOG" 2>/dev/null
      exit 1
    fi
    sleep 1
  done

  if ! is_litellm_running; then
    err "LiteLLM did not become ready within ${LITELLM_STARTUP_WAIT}s"
    err "Check log: $LITELLM_LOG"
    exit 1
  fi
fi

# ── Step 3: Quick smoke test ──
info "Smoke test: Anthropic Messages API via proxy..."
SMOKE=$(curl -sf --max-time 30 "http://localhost:${LITELLM_PORT}/v1/messages" \
  -H "x-api-key: sk-anything" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"'"${MODEL_NAME}"'","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
  2>/dev/null || echo "FAIL")

if echo "$SMOKE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'content' in d or 'error' not in d" 2>/dev/null; then
  ok "Proxy pipeline verified"
else
  warn "Smoke test returned unexpected response — proceeding anyway"
fi

# ── Step 4: Launch claude-code-hust ──
ok "Launching claude-code-hust..."
echo ""
exec ./bin/claude-hust "$@"
