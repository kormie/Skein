import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';

export default defineConfig({
  site: 'https://kormie.github.io',
  base: '/Skein/',
  integrations: [
    starlight({
      title: 'Skein',
      plugins: [
        starlightLlmsTxt({ projectName: 'Skein' }),
      ],
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Overview', slug: 'getting-started/overview' },
            { label: 'Project Structure', slug: 'getting-started/project-structure' },
            { label: 'Quickstart', slug: 'getting-started/quickstart' },
          ],
        },
        {
          label: 'Language',
          items: [
            { label: 'Syntax', slug: 'language/syntax' },
            { label: 'Types', slug: 'language/types' },
            { label: 'Expressions', slug: 'language/expressions' },
            { label: 'Modules & Functions', slug: 'language/modules-and-functions' },
          ],
        },
        {
          label: 'Compiler',
          items: [
            { label: 'Pipeline', slug: 'compiler/pipeline' },
            { label: 'Lexer', slug: 'compiler/lexer' },
            { label: 'Parser', slug: 'compiler/parser' },
            { label: 'Code Generation', slug: 'compiler/codegen' },
            { label: 'Error Handling', slug: 'compiler/errors' },
          ],
        },
        {
          label: 'Testing',
          items: [
            { label: 'Unit Tests', slug: 'testing/unit-tests' },
            { label: 'Property Tests', slug: 'testing/property-tests' },
          ],
        },
        {
          label: 'Contributing',
          items: [
            { label: 'Development', slug: 'contributing/development' },
          ],
        },
        {
          label: 'Roadmap',
          items: [
            { label: 'Phase 2', slug: 'roadmap/phase-2' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Agent Quick Reference', slug: 'reference/agent-quick-reference' },
          ],
        },
      ],
    }),
  ],
});
