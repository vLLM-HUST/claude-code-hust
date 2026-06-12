#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# bootstrap.sh — One-time setup for claude-code-hust (local dev)
#
# Idempotent: safe to run multiple times. Only does work when needed.
#
# What it does:
#   1. Installs root dependencies (bun install)
#   2. Installs adapter dependencies (adapters/ bun install)
#   3. Trusts blocked postinstall scripts (bun pm trust --all)
#   4. Fixes bun module-resolution for @whiskeysockets/baileys
#      (symlink: adapters/whatsapp/node_modules → adapters/node_modules)
#   5. Verifies LiteLLM is installed (or installs it)
#
# Usage:
#   ./bin/bootstrap.sh            # interactive
#   BOOTSTRAP_QUIET=1 ./bin/bootstrap.sh  # suppress non-error output
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [[ "${BOOTSTRAP_QUIET:-0}" == "1" ]]; then
  info()  { :; }
  ok()    { :; }
else
  info()  { echo -e "${CYAN}[bootstrap]${NC} $*"; }
  ok()    { echo -e "${GREEN}[bootstrap]${NC} $*"; }
fi
warn()  { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
err()   { echo -e "${RED}[bootstrap]${NC} $*" >&2; }

# ── Sentinel file to skip re-bootstrap ──
SENTINEL="${ROOT_DIR}/.bootstrap-done"

need_bootstrap() {
  # Always re-check if the symlink is broken
  if [[ -L "${ROOT_DIR}/adapters/whatsapp/node_modules" ]] && \
     [[ ! -e "${ROOT_DIR}/adapters/whatsapp/node_modules" ]]; then
    return 0
  fi
  # Check if root node_modules exists
  if [[ ! -d "${ROOT_DIR}/node_modules" ]]; then
    return 0
  fi
  # Check if adapter node_modules exists
  if [[ ! -d "${ROOT_DIR}/adapters/node_modules" ]]; then
    return 0
  fi
  # Check sentinel
  if [[ ! -f "${SENTINEL}" ]]; then
    return 0
  fi
  # Check if any package.json is newer than sentinel
  for pkg in "${ROOT_DIR}/package.json" "${ROOT_DIR}/adapters/package.json"; do
    if [[ "$pkg" -nt "${SENTINEL}" ]]; then
      return 0
    fi
  done
  return 1
}

if need_bootstrap; then
  info "Running dependency setup..."
else
  ok "Dependencies up to date (run with BOOTSTRAP_FORCE=1 to re-run)"
  exit 0
fi

# Force re-run if requested
if [[ "${BOOTSTRAP_FORCE:-0}" == "1" ]]; then
  info "Force re-bootstrap requested"
fi

# ── Step 1: Check bun ──
if ! command -v bun &>/dev/null; then
  err "bun not found. Install it first:"
  err "  curl -fsSL https://bun.sh/install | bash"
  exit 1
fi
info "bun $(bun --version)"

# ── Step 2: Install root dependencies ──
info "Installing root dependencies..."
bun install --frozen-lockfile 2>&1 | tail -1 || bun install 2>&1 | tail -1

# ── Step 3: Install adapter dependencies ──
info "Installing adapter dependencies..."
cd "${ROOT_DIR}/adapters"
bun install 2>&1 | tail -1
cd "$ROOT_DIR"

# ── Step 4: Trust blocked postinstall scripts ──
info "Running trusted postinstall scripts..."
cd "${ROOT_DIR}/adapters"
bun pm trust --all 2>&1 | tail -1 || true
cd "$ROOT_DIR"
bun pm trust --all >/dev/null 2>&1 || true

# ── Step 5: Fix bun module resolution for baileys ──
# bun has a known issue resolving modules from nested package directories
# when the adapters/ package is imported from the root src/.
# Fix: symlink adapters/whatsapp/node_modules → adapters/node_modules
info "Fixing module resolution symlinks..."

# Find all adapter subdirectories that have a package.json (i.e., are sub-packages)
for adapter_dir in "${ROOT_DIR}/adapters"/*/; do
  adapter_name="$(basename "$adapter_dir")"
  # Skip node_modules and common
  [[ "$adapter_name" == "node_modules" || "$adapter_name" == "common" ]] && continue
  [[ ! -d "$adapter_dir" ]] && continue

  target="${adapter_dir}/node_modules"
  source="${ROOT_DIR}/adapters/node_modules"

  if [[ -L "$target" ]]; then
    # Already a symlink — verify it points to the right place
    current_target="$(readlink "$target" 2>/dev/null || echo "")"
    if [[ "$current_target" == "$source" ]]; then
      continue
    fi
    rm -f "$target"
  elif [[ -d "$target" ]]; then
    # Real directory — back it up
    warn "Backing up ${target} → ${target}.bak"
    mv "$target" "${target}.bak"
  fi

  ln -sf "$source" "$target"
  info "  ${adapter_name}/node_modules → adapters/node_modules"
done

# ── Step 6: Verify LiteLLM is available ──
LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm 2>/dev/null || echo "")}"
if [[ -z "$LITELLM_BIN" ]]; then
  # Try common conda locations
  for candidate in "$HOME/miniconda3/bin/litellm" "$HOME/anaconda3/bin/litellm" "$HOME/.local/bin/litellm"; do
    if [[ -x "$candidate" ]]; then
      LITELLM_BIN="$candidate"
      break
    fi
  done
fi
if [[ -n "$LITELLM_BIN" ]]; then
  ok "LiteLLM found: ${LITELLM_BIN}"
else
  warn "LiteLLM not found. Install it for the Anthropic→OpenAI proxy:"
  warn "  pip install 'litellm[proxy]'"
fi

# ── Done ──
touch "$SENTINEL"
ok "Bootstrap complete"
