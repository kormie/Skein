---
name: dual-docs
description: Write documentation that serves both human readers and AI agents using dual-audience conventions
allowed-tools: Read, Write, Edit, Glob, Grep
---

# Dual-Audience Documentation

Write documentation that serves both human readers and AI agents. Every content page is authored once but consumed two ways: rendered HTML for humans and raw Markdown for agents.

## The Dual-Audience Model

Documentation pages in an Astro + Starlight site produce two outputs from a single source:

1. **Human docs** — rendered HTML with navigation, visual hierarchy, and progressive disclosure. Deployed to GitHub Pages.
2. **Agent docs** — machine-optimized content following the `llms.txt` standard. Generated at build time by the `starlight-llms-txt` plugin.

The `starlight-llms-txt` plugin generates three files from content pages:

| File | Purpose | Size target |
|------|---------|-------------|
| `llms.txt` | Navigation index with links and descriptions | Small (fits any context window) |
| `llms-full.txt` | Complete documentation concatenated into one Markdown file | Full corpus |
| `llms-small.txt` | Ultra-compact version for constrained context windows | Minimal |

There is no separate content tree to maintain. The same `.md`/`.mdx` source files serve both audiences.

## Writing Rules for Agent Compatibility

AI reads documentation as **isolated chunks**, not as a continuous document. Every section must be independently meaningful when extracted from its surrounding context.

### Self-contained sections

Every section must make sense in isolation. Never use:
- "as mentioned above"
- "see the previous section"
- "the above example"
- "as we discussed"

Instead, always name the thing explicitly:

```markdown
<!-- Wrong -->
As mentioned above, the file uses YAML frontmatter.

<!-- Right -->
Ticket files use YAML frontmatter with required fields: type, project, created, priority.
```

### Consistent terminology

Read the `terminology` map from `.docs-config.json`. The keys are canonical terms; the values are synonyms to avoid.

If the config lists `"ticket": ["card", "item", "task"]`, always use "ticket" — never "card", "item", or "task" when referring to the same concept.

### Explicit nouns over pronouns

Avoid "it", "this", "these" when the antecedent could be ambiguous. Repeat the noun:

```markdown
<!-- Wrong -->
It processes them and returns the result.

<!-- Right -->
The freshness checker processes source mappings and returns a FreshnessReport.
```

### No implicit context

Do not assume the reader has read other pages. State prerequisites and definitions inline. If a concept is defined elsewhere, include a brief inline definition before linking:

```markdown
Tickets (Markdown files named `<type>--<slug>.md` stored in kanban columns)
are moved between directories to change status. See the
[Ticket Format reference](/project/reference/ticket-format) for full details.
```

### Dense opening paragraphs

Every page starts with a 2-3 sentence summary that restates the full context: what this page covers, what system it is part of, and why it matters. This is the chunk agents are most likely to retrieve.

```markdown
# Ticket Format

Kanban tickets in the dot-skills plugin are Markdown files with YAML frontmatter,
stored in column directories (`todo/`, `in-progress/`, `ready-to-review/`, `done/`).
This page documents the required and optional frontmatter fields, naming conventions,
and type prefixes used across all tickets.
```

### Strict heading hierarchy

Never skip heading levels. Every page follows H1 → H2 → H3 → H4. Agents build semantic maps from heading structure — skipping levels breaks the hierarchy.

### Fenced code blocks with language tags

Always use fenced code blocks with explicit language identifiers. Agents parse these for executable examples:

````markdown
```typescript
const config = await readDocsConfig(projectDir);
```
````

## Required Frontmatter for Agent Consumption

Every content page must include these frontmatter fields beyond the standard Starlight fields:

```yaml
---
title: Page Title
description: 1-2 sentence description optimized for search and retrieval
content-type: reference | guide | tutorial | overview
scope: module-or-component-name
ai-summary: >
  3-5 sentence dense summary of the entire page content,
  written for an agent that will not read the full page.
  Include key facts, formats, and rules.
related:
  - slug-of-related-page-1
  - slug-of-related-page-2
---
```

| Field | Purpose |
|-------|---------|
| `content-type` | Helps agents filter for the right kind of page (`reference` for lookups, `guide` for how-tos) |
| `scope` | Which plugin, module, or component this page documents |
| `ai-summary` | Pre-written chunk agents can use without parsing the full page |
| `related` | Explicit link graph so agents can navigate to related topics |

## The AI Agent Quick Reference Page

A single dedicated page configured via `agentDocs.quickReferencePage` in `.docs-config.json`. This page:

- Contains every convention, format, and rule needed to work with the project
- Is written entirely in agent-optimized style: no narrative, pure structured data, every term defined inline
- Is the page agents should read first for full project context in one shot
- Lives in the human site too (under Reference) but prioritizes agent consumption
- Functions like a comprehensive `CLAUDE.md` but publicly accessible

### What belongs in the Agent Quick Reference

- Project structure and key file locations
- All naming conventions and format specifications
- Configuration file schemas
- Command references with exact syntax
- Glossary of project-specific terms
- Workflow steps and state machines
- Every rule an agent needs to follow

## Agent Discovery Chain

Agents need reliable breadcrumbs to find documentation:

1. **`llms.txt` at site root** — primary entry point. Any agent that knows the site URL can fetch `/llms.txt`.
2. **`CLAUDE.md` / `AGENTS.md` in the repo** — reference to the published docs URL and `llms.txt` location.
3. **README** — link to the docs site for discoverability.

When creating or updating documentation, verify these discovery paths exist and point to current URLs.

## `llms-small.txt` Exclusions

The `agentDocs.llmsSmallExcludes` field in `.docs-config.json` lists section slug prefixes to exclude from `llms-small.txt`. This keeps the compact version focused on core concepts for constrained context windows. Typically excludes design docs, changelogs, and other supplementary content.
