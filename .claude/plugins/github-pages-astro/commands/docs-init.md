---
name: docs-init
description: Scaffold an Astro + Starlight doc site and generate .docs-config.json for this repo
allowed-tools: [Bash, Read, Write, Glob, Grep]
---

# docs-init

Scaffold an Astro + Starlight documentation site and generate `.docs-config.json` for this repository. This is the entry point for any new repo adopting the documentation plugin.

## Instructions

### Step 1: Gather project context

1. Read `CLAUDE.md`, `README.md`, `package.json`, and scan the directory structure to understand the project.
2. Identify likely source-of-truth files: READMEs, doc directories, config files, skill files, API modules.
3. Ask the user to confirm or adjust:
   - **Site directory name** (default: `site`)
   - **GitHub Pages base URL** (e.g., `/my-project/`)
   - **GitHub Pages site URL** (e.g., `https://user.github.io`)
   - **Initial sidebar sections** (default: Getting Started, Guides, Reference)
   - **Source-to-doc mappings** (inferred from detected files)

### Step 2: Generate `.docs-config.json`

Write the config file to the project root (`CLAUDE_PROJECT_DIR/.docs-config.json`):

```json
{
  "site": {
    "directory": "<confirmed-site-dir>",
    "baseUrl": "/<project-name>/",
    "siteUrl": "https://<user>.github.io",
    "contentDir": "src/content/docs"
  },
  "sections": [
    {
      "slug": "getting-started",
      "label": "Getting Started",
      "purpose": "Entry points for new users — overview, installation, quickstart"
    },
    {
      "slug": "guides",
      "label": "Guides",
      "purpose": "Task-oriented walkthroughs"
    },
    {
      "slug": "reference",
      "label": "Reference",
      "purpose": "Exhaustive technical details"
    }
  ],
  "sourceMappings": [],
  "terminology": {},
  "agentDocs": {
    "quickReferencePage": "reference/agent-quick-reference",
    "llmsSmallExcludes": []
  }
}
```

Populate `sourceMappings` with discovered source-to-doc relationships. Populate `terminology` based on the project domain (can be empty initially).

### Step 3: Scaffold the Astro site (if one doesn't exist)

If no Astro site exists in the configured directory:

1. Create the site directory.
2. Initialize with a `package.json`:
   ```json
   {
     "name": "<project>-docs",
     "type": "module",
     "version": "0.0.1",
     "scripts": {
       "dev": "astro dev",
       "build": "astro build",
       "preview": "astro preview"
     },
     "dependencies": {
       "@astrojs/starlight": "^0.34.0",
       "astro": "^5.7.0",
       "sharp": "^0.33.0",
       "starlight-llms-txt": "^0.3.0"
     }
   }
   ```
3. Run `bun install` in the site directory.
4. Generate `astro.config.mjs` with Starlight and `starlight-llms-txt` configuration:
   ```js
   import { defineConfig } from 'astro/config';
   import starlight from '@astrojs/starlight';
   import starlightLlmsTxt from 'starlight-llms-txt';

   export default defineConfig({
     site: '<siteUrl>',
     base: '<baseUrl>',
     integrations: [
       starlight({
         title: '<project-name>',
         plugins: [
           starlightLlmsTxt({ projectName: '<project-name>' }),
         ],
         sidebar: [/* sections from config */],
       }),
     ],
   });
   ```
5. Create `src/content.config.ts` with Starlight's content collection.
6. Create initial content pages based on detected sections.
7. Create `tsconfig.json` extending Astro's config.

**If a site already exists:** Only generate `.docs-config.json`. Do not scaffold or overwrite existing site files. If the existing `astro.config.mjs` does not include `starlight-llms-txt`, suggest adding it.

### Step 4: Scaffold GitHub Actions workflows

Generate two workflow files:

1. **`.github/workflows/deploy-docs.yml`** — deploy to GitHub Pages on push to main:
   ```yaml
   name: Deploy docs
   on:
     push:
       branches: [main]
   permissions:
     contents: read
     pages: write
     id-token: write
   concurrency:
     group: pages
     cancel-in-progress: false
   jobs:
     build:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: oven-sh/setup-bun@v2
         - run: bun install
           working-directory: <site-directory>
         - run: bunx astro build
           working-directory: <site-directory>
         - uses: actions/upload-pages-artifact@v3
           with:
             path: <site-directory>/dist
     deploy:
       needs: build
       runs-on: ubuntu-latest
       environment:
         name: github-pages
         url: ${{ steps.deployment.outputs.page_url }}
       steps:
         - id: deployment
           uses: actions/deploy-pages@v4
   ```

2. **`.github/workflows/docs-pr-check.yml`** — build check on PRs:
   ```yaml
   name: Docs PR check
   on:
     pull_request:
       paths:
         - '<site-directory>/**'
         - '.docs-config.json'
   jobs:
     build:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: oven-sh/setup-bun@v2
         - run: bun install
           working-directory: <site-directory>
         - run: bunx astro build
           working-directory: <site-directory>
   ```

### Step 5: Update agent discovery files

1. If `CLAUDE.md` exists, add a documentation section referencing the docs site URL and `llms.txt` location.
2. Suggest adding a docs link to `README.md`.

## Notes

- This command is **idempotent**. Running it on a repo that already has a site detects the existing state and only fills in missing pieces.
- All tooling uses **Bun** — no npm, npx, or Node-specific commands.
- The generated `.docs-config.json` is the bridge between the generic plugin and each specific repo.
