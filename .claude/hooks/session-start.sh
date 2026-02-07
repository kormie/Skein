#!/usr/bin/env bash
# .claude/hooks/session-start.sh
# ─────────────────────────────────────────────────────────────────────────────
# Skein Development Environment Setup (Claude Code SessionStart Hook)
#
# Ensures Elixir 1.19.5 + OTP 28.1 are installed via mise and that project
# dependencies are fetched. Persists environment so all subsequent Bash tool
# calls use the correct runtime versions.
#
# This hook is idempotent — safe to run on every session start/resume.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Only run in remote (web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# ── Parse hook input (JSON on stdin) ─────────────────────────────────────────
INPUT=$(cat)

REQUIRED_OTP="28.1"
REQUIRED_ELIXIR="1.19.5"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[skein] $*" >&2; }
ok()    { echo "[skein] OK: $*" >&2; }
fail()  { echo "[skein] FAIL: $*" >&2; exit 2; }

# ── Step 1: Fix /tmp permissions (needed for apt and builds) ─────────────────
if [ ! -w /tmp ]; then
  chmod 1777 /tmp 2>/dev/null || true
fi

# ── Step 2: Install build prerequisites ──────────────────────────────────────
install_build_deps() {
  local needs_install=false

  # Check if key build tools are present
  if ! command -v make &>/dev/null || ! command -v gcc &>/dev/null; then
    needs_install=true
  fi

  if [ "$needs_install" = true ]; then
    info "Installing build prerequisites..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq \
      build-essential autoconf m4 libncurses5-dev libssl-dev \
      libssh-dev unixodbc-dev xsltproc libxml2-utils \
      curl git 2>/dev/null || true
  fi
}

install_build_deps

# ── Step 3: Ensure mise is installed ─────────────────────────────────────────
ensure_mise() {
  # Check common install locations
  for candidate in "$HOME/.local/bin/mise" "$HOME/.mise/bin/mise"; do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      return 0
    fi
  done

  if command -v mise &>/dev/null; then
    return 0
  fi

  info "Installing mise (runtime version manager)..."
  curl -fsSL https://mise.run | sh 2>&2
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v mise &>/dev/null; then
    fail "Could not install mise. See https://mise.jdx.dev/getting-started.html"
  fi
}

ensure_mise

# Activate mise in this shell
eval "$(mise activate bash 2>/dev/null)" || true

# ── Step 4: Trust project config and install runtimes ────────────────────────
export MISE_YES=1
if [ -f "$PROJECT_DIR/.mise.toml" ]; then
  mise trust "$PROJECT_DIR/.mise.toml" 2>&1 >&2 || true
fi

install_runtimes() {
  local needs_install=false

  if ! mise ls erlang 2>/dev/null | grep -q "$REQUIRED_OTP"; then
    info "Installing Erlang/OTP $REQUIRED_OTP (may take a few minutes on first run)..."
    needs_install=true
  fi

  if ! mise ls elixir 2>/dev/null | grep -q "$REQUIRED_ELIXIR"; then
    info "Installing Elixir $REQUIRED_ELIXIR..."
    needs_install=true
  fi

  if [ "$needs_install" = true ]; then
    (cd "$PROJECT_DIR" && mise install --yes) 2>&1 | while IFS= read -r line; do
      case "$line" in
        *ompil*|*nstall*|*ownload*|*rror*|*RROR*)
          info "$line" ;;
      esac
    done || true
  fi
}

install_runtimes

# ── Step 5: Verify versions ──────────────────────────────────────────────────
verify_versions() {
  cd "$PROJECT_DIR"

  local otp_actual elixir_actual

  # otp_release returns major only ("28"), so check major matches
  otp_actual=$(mise exec -- erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "not found")
  elixir_actual=$(mise exec -- elixir --version 2>/dev/null | grep "Elixir" | awk '{print $2}' || echo "not found")

  local required_otp_major="${REQUIRED_OTP%%.*}"
  if [[ "$otp_actual" != "$required_otp_major"* ]]; then
    info "OTP version: expected $REQUIRED_OTP, got $otp_actual"
    return 1
  fi

  if [[ "$elixir_actual" != "$REQUIRED_ELIXIR"* ]]; then
    info "Elixir version: expected $REQUIRED_ELIXIR, got $elixir_actual"
    return 1
  fi

  ok "Erlang/OTP $otp_actual + Elixir $elixir_actual"
  return 0
}

verify_versions || info "Version verification failed — will try to proceed anyway"

# ── Step 6: Persist environment for subsequent Bash tool calls ───────────────
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    # Ensure mise shims/bins are on PATH
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    # Locale fix for Elixir (needs UTF-8)
    echo "export LANG=en_US.UTF-8"
    echo "export ELIXIR_ERL_OPTIONS=\"+fnu\""
    # mise environment for the project directory
    mise env --shell bash 2>/dev/null || true
  } >> "$CLAUDE_ENV_FILE"
fi

# ── Step 7: Install Hex + Rebar (needed for mix deps) ───────────────────────
install_mix_tools() {
  cd "$PROJECT_DIR"

  if ! mise exec -- mix local.hex --if-missing --force 2>/dev/null; then
    info "Hex install from registry failed, trying GitHub..."
    mise exec -- mix archive.install github hexpm/hex branch latest --force 2>/dev/null || true
  fi

  mise exec -- mix local.rebar --if-missing --force 2>/dev/null || true
}

install_mix_tools

# ── Step 8: Fetch project dependencies ───────────────────────────────────────
fetch_deps() {
  cd "$PROJECT_DIR"

  if [ -f "mix.exs" ]; then
    if [ ! -d "deps" ] || [ "mix.exs" -nt "deps" ] 2>/dev/null; then
      info "Fetching mix dependencies..."
      mise exec -- mix deps.get 2>&1 | tail -5 >&2 || true
    fi

    # Compile deps to speed up first test/format run
    if [ ! -d "_build" ]; then
      info "Compiling project..."
      mise exec -- mix compile 2>&1 | tail -5 >&2 || true
    fi
  fi
}

fetch_deps

ok "Environment ready"

# ── Output context for Claude (JSON on stdout) ───────────────────────────────
cat <<CONTEXT_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Development environment ready: Elixir ${REQUIRED_ELIXIR} on OTP ${REQUIRED_OTP} (managed by mise). Use 'mix test' to run tests and 'mix format' to lint. Project: ${PROJECT_DIR}"
  }
}
CONTEXT_JSON
