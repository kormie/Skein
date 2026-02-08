---
name: docs-dev
description: Start the documentation site dev server for live preview
allowed-tools: [Bash, Read]
---

# docs-dev

Start the Astro documentation site dev server for live preview.

## Instructions

1. Read `CLAUDE_PROJECT_DIR/.docs-config.json` to get the site directory and base URL.
   - If `.docs-config.json` does not exist, tell the user to run `/docs-init` first.

2. Check that Bun is installed:
   ```bash
   command -v bun
   ```
   If not installed, tell the user to install Bun.

3. Install dependencies if `node_modules/` does not exist in the site directory:
   ```bash
   cd "<site-directory>" && bun install
   ```

4. Start the dev server in the background from the site directory:
   ```bash
   cd "<site-directory>" && bunx astro dev &
   echo $! > .astro-dev.pid
   ```

5. Save the PID to `<site-directory>/.astro-dev.pid` for cleanup by the SessionEnd hook.

6. Print the local URL for the user:
   ```
   Dev server running at http://localhost:4321<baseUrl>
   ```

7. Inform the user:
   - The dev server is running at the printed URL
   - Changes to content files will hot-reload automatically
   - The server will auto-stop when the Claude session ends
   - To stop manually: check the PID in `.astro-dev.pid` or run `pkill -f "astro dev"`

## Notes

- Do **not** attempt to open a browser. Print the URL and let the user open it.
- The SessionEnd hook (`stop-dev-server.sh`) will clean up the process automatically.
