---
name: docs-sync
description: Check documentation freshness against the codebase
allowed-tools: [Bash, Read, Glob, Grep]
---

# docs-sync

Perform a documentation freshness audit driven by `.docs-config.json`. Produces a report of stale, missing, or diverged documentation with suggested actions.

## Instructions

1. Read `CLAUDE_PROJECT_DIR/.docs-config.json` to get site configuration.
   - If `.docs-config.json` does not exist, tell the user to run `/docs-init` first.

2. Run the freshness check script:
   ```bash
   bun run "${CLAUDE_PROJECT_DIR}/.claude/plugins/github-pages-astro/scripts/freshness-check.ts" "${CLAUDE_PROJECT_DIR}" "${CLAUDE_PROJECT_DIR}/.docs-config.json"
   ```

3. Parse the JSON output into a structured report. The report contains these categories:

### Content Freshness

**Source mapping staleness** — For each entry in `sourceMappings`, the script compares modification timestamps of source files against their mapped doc pages. Flag entries where a source was modified more recently than its corresponding docs.

**Sidebar completeness** — Verify every `.md`/`.mdx` file in the content directory has a sidebar entry in `astro.config.mjs`, and vice versa. Report orphaned sidebar entries and undocumented pages.

**Source coverage discovery** — Expand all glob patterns in `sourceMappings` and check for new files matching existing patterns that are not yet explicitly documented. These are potentially unmapped sources.

### Agent-Readiness Audit (warnings only)

**Frontmatter completeness** — Check that every content page has recommended agent frontmatter fields: `content-type`, `scope`, `ai-summary`, `related`. Report as warnings, not errors.

**Self-containment check** — Scan for anti-patterns in content pages:
- "as mentioned above"
- "see above"
- "the previous section"
- Vague pronouns at section starts ("It", "This", "These" without clear antecedents)

**Terminology consistency** — Using the `terminology` map from `.docs-config.json`, flag pages that use synonym terms instead of the canonical term.

**Agent quick reference freshness** — If `agentDocs.quickReferencePage` is configured, verify the page exists and has been updated recently.

### Agent Discovery Verification

**CLAUDE.md/AGENTS.md reference check** — Verify that `CLAUDE.md` or `AGENTS.md` contains a reference to the published docs URL and `llms.txt` location. Flag if missing or if the URL appears stale.

4. Present the report to the user, grouped by category:
   - **Errors** (content freshness issues that should be fixed)
   - **Warnings** (agent-readiness issues to consider)
   - **Info** (discovery and coverage observations)

5. Work through the report items as a todo list, addressing errors first, then warnings.

## Notes

- This command produces a **report, not auto-fixes**. Doc pages may have framework-specific formatting that raw copying would break.
- Agent-readiness checks are **warnings only** — missing `ai-summary` fields are noted but not blocking.
- Freshness checks are **config-driven** — only files declared in `sourceMappings` are checked. The command does not guess about undeclared directories.
- New unmapped sources are discovered by matching existing glob patterns, not by separate heuristics.
