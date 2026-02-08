#!/usr/bin/env bun
/**
 * freshness-check.ts
 *
 * Performs a documentation freshness audit driven by .docs-config.json.
 * Used by both the /docs-sync command and the docs-freshness-check Stop hook.
 *
 * Usage:
 *   bun run freshness-check.ts <project-root> <config-path>
 *
 * Output: JSON FreshnessReport to stdout
 */

import { readFileSync, statSync, existsSync } from "fs";
import { join, relative } from "path";
import { Glob } from "bun";

// --- Types ---

interface DocsConfig {
  site: {
    directory: string;
    baseUrl: string;
    siteUrl: string;
    contentDir: string;
  };
  sections: Array<{
    slug: string;
    label: string;
    purpose: string;
  }>;
  sourceMappings: Array<{
    source: string;
    docs: string[];
  }>;
  terminology: Record<string, string[]>;
  agentDocs: {
    quickReferencePage: string;
    llmsSmallExcludes: string[];
  };
}

interface FreshnessReport {
  sidebarOrphans: string[];
  undocumentedPages: string[];
  stalePages: StaleItem[];
  newSourceMatches: SourceMatch[];
  agentWarnings: AgentWarning[];
  discoveryIssues: string[];
}

interface StaleItem {
  docPage: string;
  sourceFile: string;
  reason: string;
}

interface SourceMatch {
  file: string;
  matchedPattern: string;
  suggestedDocs: string[];
}

interface AgentWarning {
  page: string;
  issue: string;
}

// --- Helpers ---

function parseFrontmatter(content: string): Record<string, unknown> {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return {};

  const yaml = match[1];
  const result: Record<string, unknown> = {};

  for (const line of yaml.split("\n")) {
    const colonIdx = line.indexOf(":");
    if (colonIdx === -1) continue;
    const key = line.slice(0, colonIdx).trim();
    const value = line.slice(colonIdx + 1).trim();
    if (key && value) {
      result[key] = value;
    }
  }

  return result;
}

function getModTime(filePath: string): number {
  try {
    return statSync(filePath).mtimeMs;
  } catch {
    return 0;
  }
}

function expandGlob(pattern: string, cwd: string): string[] {
  const glob = new Glob(pattern);
  const matches: string[] = [];
  for (const match of glob.scanSync({ cwd, onlyFiles: true })) {
    matches.push(match);
  }
  return matches;
}

function findContentFiles(contentDir: string): string[] {
  if (!existsSync(contentDir)) return [];
  const glob = new Glob("**/*.{md,mdx}");
  const files: string[] = [];
  for (const match of glob.scanSync({ cwd: contentDir, onlyFiles: true })) {
    files.push(match);
  }
  return files;
}

function extractSidebarSlugs(astroConfigPath: string): string[] {
  if (!existsSync(astroConfigPath)) return [];
  const content = readFileSync(astroConfigPath, "utf-8");

  const slugs: string[] = [];
  const slugRegex = /slug:\s*['"]([^'"]+)['"]/g;
  let match;
  while ((match = slugRegex.exec(content)) !== null) {
    slugs.push(match[1]);
  }
  return slugs;
}

// Anti-patterns that indicate non-self-contained sections
const SELF_CONTAINMENT_PATTERNS = [
  /\bas mentioned above\b/i,
  /\bsee above\b/i,
  /\bthe previous section\b/i,
  /\bas we discussed\b/i,
  /\bas noted earlier\b/i,
  /\bsee the previous\b/i,
];

// --- Main ---

function runFreshnessCheck(
  projectRoot: string,
  configPath: string
): FreshnessReport {
  const report: FreshnessReport = {
    sidebarOrphans: [],
    undocumentedPages: [],
    stalePages: [],
    newSourceMatches: [],
    agentWarnings: [],
    discoveryIssues: [],
  };

  // Read config
  if (!existsSync(configPath)) {
    report.discoveryIssues.push(
      ".docs-config.json not found. Run /docs-init to generate it."
    );
    return report;
  }

  const config: DocsConfig = JSON.parse(readFileSync(configPath, "utf-8"));
  const siteDir = join(projectRoot, config.site.directory);
  const contentDir = join(siteDir, config.site.contentDir);
  const astroConfigPath = join(siteDir, "astro.config.mjs");

  // --- Source mapping staleness ---
  for (const mapping of config.sourceMappings) {
    const sourceFiles = mapping.source.includes("*")
      ? expandGlob(mapping.source, projectRoot)
      : existsSync(join(projectRoot, mapping.source))
        ? [mapping.source]
        : [];

    for (const sourceFile of sourceFiles) {
      const sourceModTime = getModTime(join(projectRoot, sourceFile));
      if (sourceModTime === 0) continue;

      for (const docSlug of mapping.docs) {
        // Try both .md and .mdx
        let docPath = join(contentDir, `${docSlug}.md`);
        if (!existsSync(docPath)) {
          docPath = join(contentDir, `${docSlug}.mdx`);
        }

        const docModTime = getModTime(docPath);

        if (docModTime === 0) {
          report.stalePages.push({
            docPage: docSlug,
            sourceFile,
            reason: "doc page does not exist",
          });
        } else if (sourceModTime > docModTime) {
          report.stalePages.push({
            docPage: docSlug,
            sourceFile,
            reason: "source modified more recently than doc",
          });
        }
      }
    }
  }

  // --- Sidebar completeness ---
  const sidebarSlugs = extractSidebarSlugs(astroConfigPath);
  const contentFiles = findContentFiles(contentDir);

  // Convert content files to slugs (remove extension, normalize)
  const contentSlugs = contentFiles.map((f) =>
    f.replace(/\.(md|mdx)$/, "").replace(/\/index$/, "")
  );

  // Sidebar entries with no matching content file
  for (const slug of sidebarSlugs) {
    if (!contentSlugs.includes(slug) && slug !== "index") {
      report.sidebarOrphans.push(slug);
    }
  }

  // Content files with no sidebar entry
  for (const slug of contentSlugs) {
    if (slug === "index") continue; // Landing page doesn't need sidebar entry
    if (!sidebarSlugs.includes(slug)) {
      report.undocumentedPages.push(slug);
    }
  }

  // --- Source coverage discovery ---
  for (const mapping of config.sourceMappings) {
    if (!mapping.source.includes("*")) continue;

    const matches = expandGlob(mapping.source, projectRoot);
    // Check if any matches are files that don't already have explicit mappings
    for (const match of matches) {
      const hasExplicitMapping = config.sourceMappings.some(
        (m) => m.source === match
      );
      if (!hasExplicitMapping) {
        report.newSourceMatches.push({
          file: match,
          matchedPattern: mapping.source,
          suggestedDocs: mapping.docs,
        });
      }
    }
  }

  // --- Agent-readiness audit ---
  for (const contentFile of contentFiles) {
    const filePath = join(contentDir, contentFile);
    const content = readFileSync(filePath, "utf-8");
    const frontmatter = parseFrontmatter(content);
    const slug = contentFile.replace(/\.(md|mdx)$/, "");

    // Check required agent frontmatter
    const requiredFields = ["content-type", "scope", "ai-summary"];
    for (const field of requiredFields) {
      if (!frontmatter[field]) {
        report.agentWarnings.push({
          page: slug,
          issue: `missing ${field} frontmatter field`,
        });
      }
    }

    if (!frontmatter["related"]) {
      report.agentWarnings.push({
        page: slug,
        issue: "missing related frontmatter field",
      });
    }

    // Self-containment check
    for (const pattern of SELF_CONTAINMENT_PATTERNS) {
      if (pattern.test(content)) {
        report.agentWarnings.push({
          page: slug,
          issue: `contains non-self-contained reference: "${content.match(pattern)?.[0]}"`,
        });
      }
    }

    // Terminology consistency
    for (const [canonical, synonyms] of Object.entries(config.terminology)) {
      for (const synonym of synonyms) {
        const synonymRegex = new RegExp(`\\b${synonym}\\b`, "gi");
        if (synonymRegex.test(content)) {
          report.agentWarnings.push({
            page: slug,
            issue: `uses synonym "${synonym}" instead of canonical term "${canonical}"`,
          });
        }
      }
    }
  }

  // Agent quick reference freshness
  if (config.agentDocs?.quickReferencePage) {
    const qrSlug = config.agentDocs.quickReferencePage;
    let qrPath = join(contentDir, `${qrSlug}.md`);
    if (!existsSync(qrPath)) {
      qrPath = join(contentDir, `${qrSlug}.mdx`);
    }
    if (!existsSync(qrPath)) {
      report.agentWarnings.push({
        page: qrSlug,
        issue: "Agent Quick Reference page does not exist",
      });
    }
  }

  // --- Agent discovery verification ---
  const claudeMdPath = join(projectRoot, "CLAUDE.md");
  const agentsMdPath = join(projectRoot, "AGENTS.md");
  const docsUrl = `${config.site.siteUrl}${config.site.baseUrl}`;

  let hasDiscoveryRef = false;
  for (const discoveryFile of [claudeMdPath, agentsMdPath]) {
    if (existsSync(discoveryFile)) {
      const content = readFileSync(discoveryFile, "utf-8");
      if (content.includes("llms.txt") || content.includes(docsUrl)) {
        hasDiscoveryRef = true;
      }
    }
  }

  if (!hasDiscoveryRef) {
    report.discoveryIssues.push(
      `Neither CLAUDE.md nor AGENTS.md references the docs site (${docsUrl}) or llms.txt. ` +
        "Add a documentation section so agents can discover the docs."
    );
  }

  return report;
}

// --- CLI entrypoint ---

const [projectRoot, configPath] = process.argv.slice(2);

if (!projectRoot || !configPath) {
  console.error(
    "Usage: bun run freshness-check.ts <project-root> <config-path>"
  );
  process.exit(1);
}

const report = runFreshnessCheck(projectRoot, configPath);
console.log(JSON.stringify(report, null, 2));
