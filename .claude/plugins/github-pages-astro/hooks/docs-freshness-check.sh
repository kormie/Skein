#!/usr/bin/env bash
set -eo pipefail

# Stop hook: Remind Claude to update docs when source files are modified
# but their corresponding doc pages are not.
#
# Exit 0 = all good, agent can stop
# Exit 2 + stderr = soft block, stderr message fed back to Claude
#
# This hook is conservative — it only fires when there's a clear signal
# that docs are stale. False positives train users to ignore the hook.

CONFIG_FILE="${CLAUDE_PROJECT_DIR}/.docs-config.json"

# If .docs-config.json doesn't exist, this repo hasn't initialized the plugin
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0
fi

# Check if jq-like parsing is available via bun
if ! command -v bun &>/dev/null; then
  # Can't run the check without bun, silently pass
  exit 0
fi

# Get modified files in this session (staged + unstaged)
MODIFIED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
if [[ -z "$MODIFIED_FILES" ]]; then
  # Also check staged but uncommitted changes
  MODIFIED_FILES=$(git diff --name-only --cached 2>/dev/null || true)
fi

if [[ -z "$MODIFIED_FILES" ]]; then
  exit 0
fi

# Read site directory and content dir from config
SITE_DIR=$(bun -e "
  const config = JSON.parse(require('fs').readFileSync('${CONFIG_FILE}', 'utf-8'));
  console.log(config.site.directory);
")
CONTENT_DIR=$(bun -e "
  const config = JSON.parse(require('fs').readFileSync('${CONFIG_FILE}', 'utf-8'));
  console.log(config.site.contentDir);
")

# Read source mappings and check if any modified files match
STALE_DOCS=$(bun -e "
  const fs = require('fs');
  const config = JSON.parse(fs.readFileSync('${CONFIG_FILE}', 'utf-8'));
  const modified = \`${MODIFIED_FILES}\`.split('\n').filter(Boolean);
  const sitePrefix = config.site.directory + '/' + config.site.contentDir + '/';

  // Separate modified into source files and doc files
  const modifiedDocs = new Set(
    modified
      .filter(f => f.startsWith(sitePrefix))
      .map(f => f.slice(sitePrefix.length).replace(/\.(md|mdx)$/, ''))
  );

  const stale = [];

  for (const mapping of config.sourceMappings) {
    const pattern = mapping.source;

    for (const file of modified) {
      // Simple glob matching: exact match or pattern prefix match
      let matches = false;
      if (pattern.includes('*')) {
        const prefix = pattern.split('*')[0];
        matches = file.startsWith(prefix);
      } else {
        matches = file === pattern;
      }

      if (matches) {
        // Check if any corresponding doc pages were also modified
        const unmatchedDocs = mapping.docs.filter(d => !modifiedDocs.has(d));
        if (unmatchedDocs.length > 0) {
          stale.push({ source: file, docs: unmatchedDocs });
        }
      }
    }
  }

  if (stale.length > 0) {
    console.log(JSON.stringify(stale));
  }
" 2>/dev/null || true)

if [[ -z "$STALE_DOCS" ]]; then
  exit 0
fi

# Build the reminder message
{
  echo "REMINDER: Source files were modified but corresponding doc pages may need updating."
  echo ""
  echo "The following source-to-doc mappings have stale documentation:"
  echo ""

  echo "$STALE_DOCS" | bun -e "
    const stale = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf-8'));
    for (const item of stale) {
      console.log('  Source: ' + item.source);
      for (const doc of item.docs) {
        console.log('    → Doc page may need update: ' + doc);
      }
      console.log('');
    }
  " 2>/dev/null || true

  echo "Consider running /docs-sync for a full freshness audit."
  echo "If these docs are already up to date, you can safely proceed."
} >&2

exit 2
