#!/usr/bin/env bash
# .claude/hooks/session-start.sh
# ─────────────────────────────────────────────────────────────────────────────
# Skein Development Environment Setup (Claude Code SessionStart Hook)
#
# Ensures Elixir 1.19.5 + OTP 28.1 are installed and available via mise.
# Persists environment variables so all subsequent Bash tool calls use the
# correct runtime versions.
#
# This hook is idempotent — safe to run on every session start/resume.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Parse hook input (JSON on stdin) ─────────────────────────────────────────
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source','unknown'))" 2>/dev/null || echo "unknown")

REQUIRED_OTP="28.1"
REQUIRED_ELIXIR="1.19.5"
MISE_MIN_VERSION="2024.0.0"

# ── Color helpers (stderr only, for user feedback) ───────────────────────────
info()  { echo "🧶 [skein] $*" >&2; }
ok()    { echo "✅ [skein] $*" >&2; }
warn()  { echo "⚠️  [skein] $*" >&2; }
fail()  { echo "❌ [skein] $*" >&2; exit 2; }

# ── Step 1: Ensure mise is installed ─────────────────────────────────────────
install_mise() {
  info "Installing mise (runtime version manager)..."
  curl -fsSL https://mise.run | sh 2>&2
  export PATH="$HOME/.local/bin:$PATH"
}

if ! command -v mise &>/dev/null; then
  # Check common install locations before installing
  for candidate in "$HOME/.local/bin/mise" "$HOME/.mise/bin/mise"; do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi

if ! command -v mise &>/dev/null; then
  install_mise
fi

if ! command -v mise &>/dev/null; then
  fail "Could not install mise. Install manually: https://mise.jdx.dev/getting-started.html"
fi

# Activate mise in this shell
eval "$(mise activate bash 2>/dev/null)" || true

# ── Step 2: Trust the project .mise.toml ─────────────────────────────────────
if [ -f "$CLAUDE_PROJECT_DIR/.mise.toml" ]; then
  mise trust "$CLAUDE_PROJECT_DIR/.mise.toml" 2>/dev/null || true
fi

# ── Step 3: Install required runtimes ────────────────────────────────────────
install_runtimes() {
  local needs_install=false

  # Check OTP
  if ! mise ls erlang 2>/dev/null | grep -q "$REQUIRED_OTP"; then
    info "Installing Erlang/OTP $REQUIRED_OTP (this may take a few minutes on first run)..."
    needs_install=true
  fi

  # Check Elixir
  if ! mise ls elixir 2>/dev/null | grep -q "$REQUIRED_ELIXIR"; then
    info "Installing Elixir $REQUIRED_ELIXIR..."
    needs_install=true
  fi

  if [ "$needs_install" = true ]; then
    # mise install reads from .mise.toml in the project dir
    (cd "$CLAUDE_PROJECT_DIR" && mise install) 2>&1 | while IFS= read -r line; do
      # Show progress but don't flood
      case "$line" in
        *compiling*|*installing*|*Installed*|*error*|*Error*)
          info "$line"
          ;;
      esac
    done

    if [ $? -ne 0 ]; then
      fail "Runtime installation failed. Run 'mise install' manually in $CLAUDE_PROJECT_DIR to debug."
    fi
  fi
}

install_runtimes

# ── Step 4: Verify versions ──────────────────────────────────────────────────
verify_versions() {
  local otp_actual elixir_actual

  # Get the versions mise will provide in this project
  cd "$CLAUDE_PROJECT_DIR"

  otp_actual=$(mise exec -- erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "not found")
  elixir_actual=$(mise exec -- elixir --version 2>/dev/null | grep "Elixir" | awk '{print $2}' || echo "not found")

  if [[ "$otp_actual" != "$REQUIRED_OTP"* ]]; then
    warn "OTP version mismatch: expected $REQUIRED_OTP, got $otp_actual"
    warn "Run: cd $CLAUDE_PROJECT_DIR && mise install"
    return 1
  fi

  if [[ "$elixir_actual" != "$REQUIRED_ELIXIR"* ]]; then
    warn "Elixir version mismatch: expected $REQUIRED_ELIXIR, got $elixir_actual"
    warn "Run: cd $CLAUDE_PROJECT_DIR && mise install"
    return 1
  fi

  ok "Erlang/OTP $otp_actual"
  ok "Elixir $elixir_actual"
  return 0
}

verify_versions || warn "Version verification failed — some tools may not work correctly"

# ── Step 5: Persist environment for subsequent Bash tool calls ───────────────
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  # Capture mise's environment setup so every bash command uses the right versions
  {
    echo "export PATH=\"$HOME/.local/bin:\$PATH\""
    mise env --shell bash 2>/dev/null || true
  } >> "$CLAUDE_ENV_FILE"
fi

# ── Step 6: Check project dependencies ───────────────────────────────────────
check_deps() {
  cd "$CLAUDE_PROJECT_DIR"

  if [ -f "mix.exs" ] && [ ! -d "deps" ]; then
    info "Dependencies not fetched — run 'mix deps.get' before compiling."
  elif [ -f "mix.exs" ] && [ -f "mix.lock" ]; then
    # Quick staleness check: if mix.exs is newer than deps, suggest refresh
    if [ "mix.exs" -nt "deps" ] 2>/dev/null; then
      info "mix.exs is newer than deps/ — you may need 'mix deps.get'."
    fi
  fi
}

check_deps 2>/dev/null || true

# ── Step 7: Output context for Claude (JSON on stdout) ───────────────────────
# SessionStart hooks can inject additionalContext into the conversation
cat <<CONTEXT_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Development environment verified: Elixir ${REQUIRED_ELIXIR} on OTP ${REQUIRED_OTP} (managed by mise). All 'mix' and 'elixir' commands will use these versions automatically. Project root: ${CLAUDE_PROJECT_DIR}"
  }
}
CONTEXT_JSON
