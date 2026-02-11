import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';
import { readFileSync } from 'node:fs';

// Canonical Skein grammar lives in editors/vscode/ — single source of truth
// for the VS Code extension, docs site, and any future editor integrations.
const skeinGrammarRaw = JSON.parse(
  readFileSync(new URL('../../editors/vscode/skein.tmLanguage.json', import.meta.url), 'utf-8')
);
const skeinGrammar = { ...skeinGrammarRaw, name: 'skein' };

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
      logo: {
        src: './src/assets/logo.svg',
      },
      customCss: [
        './src/styles/custom.css',
      ],
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
            { label: 'Agents', slug: 'language/agents' },
            { label: 'Tools', slug: 'language/tools' },
            { label: 'Supervisors', slug: 'language/supervisors' },
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
            { label: 'Storage', slug: 'runtime/storage' },
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
          label: 'Editor Support',
          items: [
            { label: 'VS Code Extension', slug: 'editor/vscode' },
            { label: 'Language Server (LSP)', slug: 'editor/language-server' },
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
            { label: 'Distribution', slug: 'roadmap/distribution' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Standard Library', slug: 'reference/stdlib' },
            { label: 'API Reference (ExDoc)', link: '/Skein/api/' },
            { label: 'Agent Quick Reference', slug: 'reference/agent-quick-reference' },
          ],
        },
      ],
    }),
  ],
});
