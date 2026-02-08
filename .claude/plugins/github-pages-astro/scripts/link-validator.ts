#!/usr/bin/env bun
/**
 * link-validator.ts
 *
 * Validates internal links in the built Astro site output.
 * Crawls the dist/ directory and checks that all internal links,
 * anchor references, and image sources resolve to existing files.
 *
 * Usage:
 *   bun run link-validator.ts <dist-directory>
 *
 * Output: JSON array of broken links to stdout. Empty array = all valid.
 */

import { readFileSync, existsSync } from "fs";
import { join, dirname, resolve } from "path";
import { Glob } from "bun";

// --- Types ---

interface BrokenLink {
  sourcePage: string;
  target: string;
  type: "internal-link" | "anchor" | "image";
  reason: string;
}

// --- Helpers ---

function findHtmlFiles(distDir: string): string[] {
  const glob = new Glob("**/*.html");
  const files: string[] = [];
  for (const match of glob.scanSync({ cwd: distDir, onlyFiles: true })) {
    files.push(match);
  }
  return files;
}

function extractLinks(html: string): Array<{ href: string; type: "internal-link" | "anchor" | "image" }> {
  const links: Array<{ href: string; type: "internal-link" | "anchor" | "image" }> = [];

  // Extract href attributes from <a> tags
  const hrefRegex = /<a\s[^>]*href=["']([^"']+)["']/gi;
  let match;
  while ((match = hrefRegex.exec(html)) !== null) {
    const href = match[1];
    // Skip external links, mailto, tel, javascript
    if (/^(https?:|mailto:|tel:|javascript:)/i.test(href)) continue;

    if (href.startsWith("#")) {
      links.push({ href, type: "anchor" });
    } else {
      links.push({ href, type: "internal-link" });
    }
  }

  // Extract src attributes from <img> tags
  const srcRegex = /<img\s[^>]*src=["']([^"']+)["']/gi;
  while ((match = srcRegex.exec(html)) !== null) {
    const src = match[1];
    if (/^(https?:|data:)/i.test(src)) continue;
    links.push({ href: src, type: "image" });
  }

  return links;
}

function extractHeadingIds(html: string): string[] {
  const ids: string[] = [];
  const idRegex = /id=["']([^"']+)["']/gi;
  let match;
  while ((match = idRegex.exec(html)) !== null) {
    ids.push(match[1]);
  }
  return ids;
}

function resolveInternalLink(
  href: string,
  sourceFile: string,
  distDir: string
): string | null {
  // Remove anchor portion for file resolution
  const [path] = href.split("#");
  if (!path) return null; // Pure anchor link

  let targetPath: string;
  if (path.startsWith("/")) {
    // Absolute path
    targetPath = join(distDir, path);
  } else {
    // Relative path
    targetPath = resolve(dirname(join(distDir, sourceFile)), path);
  }

  // Try exact path
  if (existsSync(targetPath)) return targetPath;

  // Try with index.html
  if (existsSync(join(targetPath, "index.html"))) return join(targetPath, "index.html");

  // Try with .html extension
  if (existsSync(`${targetPath}.html`)) return `${targetPath}.html`;

  return null;
}

// --- Main ---

function validateLinks(distDir: string): BrokenLink[] {
  const broken: BrokenLink[] = [];

  if (!existsSync(distDir)) {
    console.error(`dist directory not found: ${distDir}`);
    process.exit(1);
  }

  const htmlFiles = findHtmlFiles(distDir);

  for (const file of htmlFiles) {
    const filePath = join(distDir, file);
    const html = readFileSync(filePath, "utf-8");
    const links = extractLinks(html);
    const headingIds = extractHeadingIds(html);

    for (const link of links) {
      if (link.type === "anchor") {
        // Check anchor exists in current page
        const anchorId = link.href.slice(1);
        if (!headingIds.includes(anchorId)) {
          broken.push({
            sourcePage: file,
            target: link.href,
            type: "anchor",
            reason: `anchor #${anchorId} not found in page`,
          });
        }
        continue;
      }

      // Internal link or image
      const [path, anchor] = link.href.split("#");

      if (path) {
        const resolved = resolveInternalLink(link.href, file, distDir);
        if (!resolved) {
          broken.push({
            sourcePage: file,
            target: link.href,
            type: link.type,
            reason: `target file not found`,
          });
          continue;
        }

        // If there's an anchor, check it exists in the target file
        if (anchor && resolved.endsWith(".html")) {
          const targetHtml = readFileSync(resolved, "utf-8");
          const targetIds = extractHeadingIds(targetHtml);
          if (!targetIds.includes(anchor)) {
            broken.push({
              sourcePage: file,
              target: link.href,
              type: "anchor",
              reason: `anchor #${anchor} not found in target page`,
            });
          }
        }
      }
    }
  }

  return broken;
}

// --- CLI entrypoint ---

const distDir = process.argv[2];

if (!distDir) {
  console.error("Usage: bun run link-validator.ts <dist-directory>");
  process.exit(1);
}

const broken = validateLinks(distDir);
console.log(JSON.stringify(broken, null, 2));

if (broken.length > 0) {
  console.error(`\nFound ${broken.length} broken link(s)`);
  process.exit(1);
} else {
  console.error("\nAll links valid");
}
