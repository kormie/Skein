#!/bin/bash
set -eo pipefail

# SessionEnd hook: Kill the Astro dev server process and clean up the PID file.
# Reads .docs-config.json to find the site directory where the PID file lives.

CONFIG_FILE="${CLAUDE_PROJECT_DIR}/.docs-config.json"

# If no config, try common locations for PID file
if [[ ! -f "$CONFIG_FILE" ]]; then
  # Try to find and kill any astro dev process
  if pkill -f "astro dev" 2>/dev/null; then
    echo "Stopped astro dev server via pkill"
  fi
  exit 0
fi

# Read site directory from config
if command -v bun &>/dev/null; then
  SITE_DIR=$(bun -e "
    const config = JSON.parse(require('fs').readFileSync('${CONFIG_FILE}', 'utf-8'));
    console.log(config.site.directory);
  " 2>/dev/null || echo "")
else
  SITE_DIR=""
fi

PID_FILE=""

if [[ -n "$SITE_DIR" ]] && [[ -f "${CLAUDE_PROJECT_DIR}/${SITE_DIR}/.astro-dev.pid" ]]; then
  PID_FILE="${CLAUDE_PROJECT_DIR}/${SITE_DIR}/.astro-dev.pid"
elif [[ -f "${CLAUDE_PROJECT_DIR}/.astro-dev.pid" ]]; then
  PID_FILE="${CLAUDE_PROJECT_DIR}/.astro-dev.pid"
fi

if [[ -n "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill "$PID" 2>/dev/null; then
    echo "Stopped astro dev server (PID $PID)"
  else
    echo "Astro dev server (PID $PID) was already stopped"
  fi
  rm -f "$PID_FILE"
else
  # Last resort: find and kill by process name
  if pkill -f "astro dev" 2>/dev/null; then
    echo "Stopped astro dev server via pkill"
  else
    echo "No astro dev server process found"
  fi
fi
