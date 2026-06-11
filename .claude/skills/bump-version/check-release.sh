#!/usr/bin/env bash
#
# Release preflight for Skein. Verifies that the working tree is ready to cut
# the version declared in mix.exs, by running the SAME gates the release
# workflow enforces after merge (.github/workflows/release.yml, the "tag" job):
#
#   1. The root mix.exs and apps/skein_cli/mix.exs versions agree.
#   2. CHANGELOG.md has a dated `## v<version> (YYYY-MM-DD)` section.
#   3. No `skein <version>` / `Skein <version>` banner in README.md or docs/
#      has drifted from the version being shipped.
#
# Run it before merging a bump PR so the post-merge Release run can't fail on
# something catchable here. Keep this in sync with release.yml's gate logic.
#
# Usage: bash .claude/skills/bump-version/check-release.sh
# Exit:  0 = ready (or already-released no-op), 1 = problems printed above.
set -euo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}"

read_version() {
  grep -E '^[[:space:]]*version:[[:space:]]*"' "$1" | head -1 \
    | sed -E 's/.*version:[[:space:]]*"([^"]+)".*/\1/'
}

VERSION="$(read_version mix.exs || true)"
CLI_VERSION="$(read_version apps/skein_cli/mix.exs || true)"
fail=0

echo "Root mix.exs version:      ${VERSION:-<empty>}"
echo "skein_cli mix.exs version: ${CLI_VERSION:-<empty>}"

if [ -z "$VERSION" ]; then
  echo "ERROR: could not read a version from mix.exs"
  exit 1
fi

# 1. The two version sources must agree.
if [ "$VERSION" != "$CLI_VERSION" ]; then
  echo "ERROR: version mismatch — mix.exs=$VERSION, apps/skein_cli/mix.exs=$CLI_VERSION. Bump both to the same version."
  fail=1
fi

# 2. A dated CHANGELOG section is required.
ESC="$(printf '%s' "$VERSION" | sed 's/\./\\./g')"
if grep -qE "^## v${ESC} \([0-9]{4}-[0-9]{2}-[0-9]{2}\)" CHANGELOG.md; then
  echo "OK: dated CHANGELOG section for v$VERSION"
elif grep -qE "^## v${ESC}([^0-9.]|$)" CHANGELOG.md; then
  echo "ERROR: CHANGELOG.md has a '## v$VERSION' section but it is not dated. Use '## v$VERSION (YYYY-MM-DD)'."
  fail=1
else
  echo "ERROR: CHANGELOG.md has no '## v$VERSION (YYYY-MM-DD)' section. Add a dated entry."
  fail=1
fi

# 3. Version-banner drift in README.md / docs. The extraction keeps any
#    prerelease suffix so a "skein 1.0.0-rc.1" banner compares as 1.0.0-rc.1,
#    not 1.0.0.
drift=0
while IFS= read -r match; do
  [ -z "$match" ] && continue
  found="$(printf '%s' "$match" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -1)"
  if [ "$found" != "$VERSION" ]; then
    echo "ERROR: stale version banner ($found, expected $VERSION): $match"
    drift=1
  fi
done < <(grep -rEn '[Ss]kein [0-9]+\.[0-9]+\.[0-9]+' README.md docs --include='*.md' --include='*.mdx' 2>/dev/null || true)
if [ "$drift" -eq 0 ]; then
  echo "OK: no version drift in README.md / docs"
else
  fail=1
fi

# Informational: if the tag already exists, the workflow would no-op (no
# re-release). That means the version wasn't actually bumped.
if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
  echo "NOTE: tag v$VERSION already exists on origin — the release workflow will no-op (pick a new version to actually release)."
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "Release preflight FAILED for v$VERSION — fix the errors above before merging."
  exit 1
fi
echo "Release preflight PASSED for v$VERSION."
