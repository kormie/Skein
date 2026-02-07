#!/usr/bin/env bash
# .claude/hooks/post-edit.sh
# ─────────────────────────────────────────────────────────────────────────────
# Auto-format Elixir files after Write/Edit operations.
# Runs `mix format` on the changed file if it's .ex or .exs.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('file_path', ti.get('path', '')))
" 2>/dev/null || echo "")

# Only format Elixir files
case "$FILE_PATH" in
  *.ex|*.exs)
    if [ -f "$FILE_PATH" ] && command -v mix &>/dev/null; then
      mix format "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
esac

exit 0
