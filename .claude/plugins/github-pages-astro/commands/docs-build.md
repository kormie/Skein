---
name: docs-build
description: Build the documentation site and report any errors
allowed-tools: [Bash, Read]
---

# docs-build

Build the Astro documentation site and validate the output, including `llms.txt` generation.

## Instructions

1. Read `CLAUDE_PROJECT_DIR/.docs-config.json` to get the site directory.
   - If `.docs-config.json` does not exist, tell the user to run `/docs-init` first.

2. Install dependencies if needed:
   ```bash
   cd "<site-directory>" && bun install
   ```

3. Run the build:
   ```bash
   cd "<site-directory>" && bunx astro build
   ```

4. **If the build succeeds:**
   - Report success and the output path (`<site-directory>/dist/`)
   - Verify that `llms.txt` files were generated in the output:
     ```bash
     ls "<site-directory>/dist/llms.txt" "<site-directory>/dist/llms-full.txt" "<site-directory>/dist/llms-small.txt"
     ```
   - If any `llms.txt` files are missing, warn the user that the `starlight-llms-txt` plugin may not be configured correctly in `astro.config.mjs`.
   - Optionally run link validation:
     ```bash
     bun run "${CLAUDE_PROJECT_DIR}/.claude/plugins/github-pages-astro/scripts/link-validator.ts" "<site-directory>/dist"
     ```

5. **If the build fails:**
   - Display the full error output.
   - Analyze the errors and suggest fixes:
     - Missing dependencies → run `bun install`
     - Content errors → identify the problematic file and line
     - Config errors → check `astro.config.mjs`
     - Component import errors → verify import paths

## Notes

- All commands use **Bun** — no npm or npx.
- The build output goes to `<site-directory>/dist/` by default.
- The `starlight-llms-txt` plugin generates the `llms.txt` files as part of the standard Astro build — no additional build step is needed.
