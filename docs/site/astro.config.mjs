import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';
import { readFileSync } from 'node:fs';

const skeinGrammar = JSON.parse(
  readFileSync(new URL('./src/grammars/skein.tmLanguage.json', import.meta.url), 'utf-8')
);

export default defineConfig({
  site: 'https://kormie.github.io',
  base: '/Skein/',
  integrations: [
    starlight({
      expressiveCode: {
        shiki: {
          langs: [skeinGrammar],
        },
      },
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
            { label: 'Capabilities & Effects', slug: 'language/capabilities-and-effects' },
            { label: 'Handlers', slug: 'language/handlers' },
            { label: 'Tools', slug: 'language/tools' },
            { label: 'Testing', slug: 'language/testing' },
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
          label: 'Runtime',
          items: [
            { label: 'Overview', slug: 'runtime/overview' },
            { label: 'Agents', slug: 'runtime/agents' },
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
            { label: 'Full Roadmap', slug: 'roadmap/phase-2' },
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
