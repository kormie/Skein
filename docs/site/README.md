---
title: Documentation Site Content
---

# Skein Documentation Site

This directory contains structured Markdown content for a future Astro + Starlight documentation site.

## Content Structure

All files use Starlight-compatible frontmatter (`title`, `description`, `template`).

```
docs/site/
  index.md                          # Landing / splash page
  getting-started/
    overview.md                     # What is Skein, current status
    quickstart.md                   # Build and run hello.skein
    project-structure.md            # Umbrella layout and key files
  language/
    syntax.md                       # Complete syntax reference (Phase 1)
    types.md                        # Type system (current + planned)
    expressions.md                  # All expression types and compilation
    modules-and-functions.md        # Module/fn declarations and BEAM mapping
  compiler/
    pipeline.md                     # End-to-end compilation pipeline
    lexer.md                        # Token format and lexer details
    parser.md                       # Recursive descent parser internals
    codegen.md                      # Core Erlang generation via :cerl
    errors.md                       # Structured error format
  testing/
    unit-tests.md                   # ExUnit test patterns and conventions
    property-tests.md               # StreamData property-based testing
  roadmap/
    phase-2.md                      # Full phase status and what's next
  contributing/
    development.md                  # Dev setup, conventions, workflow
```

## Setting Up Astro + Starlight

To create the documentation site:

```bash
npm create astro@latest -- --template starlight skein-docs
cd skein-docs
```

Then copy these files into `src/content/docs/`:

```bash
cp -r docs/site/* skein-docs/src/content/docs/
```

Configure the sidebar in `astro.config.mjs`:

```javascript
export default defineConfig({
  integrations: [
    starlight({
      title: 'Skein',
      social: { github: '<repo-url>' },
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Overview', link: '/getting-started/overview/' },
            { label: 'Quickstart', link: '/getting-started/quickstart/' },
            { label: 'Project Structure', link: '/getting-started/project-structure/' },
          ],
        },
        {
          label: 'Language',
          items: [
            { label: 'Syntax', link: '/language/syntax/' },
            { label: 'Types', link: '/language/types/' },
            { label: 'Expressions', link: '/language/expressions/' },
            { label: 'Modules & Functions', link: '/language/modules-and-functions/' },
          ],
        },
        {
          label: 'Compiler Internals',
          items: [
            { label: 'Pipeline', link: '/compiler/pipeline/' },
            { label: 'Lexer', link: '/compiler/lexer/' },
            { label: 'Parser', link: '/compiler/parser/' },
            { label: 'Code Generator', link: '/compiler/codegen/' },
            { label: 'Errors', link: '/compiler/errors/' },
          ],
        },
        {
          label: 'Testing',
          items: [
            { label: 'Unit Tests', link: '/testing/unit-tests/' },
            { label: 'Property Tests', link: '/testing/property-tests/' },
          ],
        },
        {
          label: 'Roadmap',
          items: [
            { label: 'Phases & Status', link: '/roadmap/phase-2/' },
          ],
        },
        {
          label: 'Contributing',
          items: [
            { label: 'Development Guide', link: '/contributing/development/' },
          ],
        },
      ],
    }),
  ],
});
```

## Content Conventions

- All content reflects the **current implementation state** (Phase 1 complete)
- Future features are clearly marked as "parsed but not compiled" or "planned"
- Code examples use actual Skein syntax and real Elixir API calls
- Compiler internals include Core Erlang output examples
- Property test coverage is documented per component
