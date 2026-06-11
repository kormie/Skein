---
name: bump-version
description: Cut a new Skein release by bumping the version. Use when the user wants to release a new version, bump the version, or prepare a release PR (e.g. "bump to 0.1.6", "cut a release", "prepare the next version"). Updates mix.exs, the CHANGELOG, and the doc version banners; verifies them against the release gates; and opens the release PR.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
---

# Bump the Skein release version

Releasing Skein is **"merge one PR that bumps the version."** Merging that PR to
`main` with green CI is what triggers the automated tag + four-target binary
build + GitHub Release (`.github/workflows/release.yml` → `build.yml`). There is
no manual `git tag` step.

This skill prepares that PR and verifies it against the **same gates the release
workflow enforces after merge**, so nothing half-releases.

## Inputs

- **Target version** (e.g. `0.1.6`). If the user didn't specify one, read the
  current version from `mix.exs` and propose the next patch bump, then confirm
  before proceeding. Use plain `MAJOR.MINOR.PATCH` (no `v` prefix in the files;
  the tag will be `v<version>`).

## Steps

1. **Confirm the target version.** Read the current version:
   ```bash
   grep -m1 -E '^\s*version:' mix.exs
   ```
   Establish `PREV` (current) and `NEW` (target).

2. **Bump both mix.exs files — they MUST match** (the release job fails if they
   disagree):
   - `mix.exs` (root) → `version: "<NEW>"`
   - `apps/skein_cli/mix.exs` → `version: "<NEW>"`

   Leave the per-app `skein_compiler` / `skein_runtime` / `skein_lsp` versions
   alone — only the root and `skein_cli` are part of the release-version
   contract.

3. **Add a dated CHANGELOG section.** Insert `## v<NEW> (YYYY-MM-DD)` (today's
   date) at the top of `CHANGELOG.md`, directly above the previous version's
   section. Draft the notes from the work merged since the last release:
   ```bash
   git log --no-merges "v<PREV>..HEAD" --pretty='- %s'
   ```
   Summarize into the changelog's existing section headings (Language &
   Compiler, CLI, Runtime, Testing, Spec & Docs, CI, VS Code Extension, …).
   Write for humans — group and explain, don't dump raw commit subjects.

4. **Update the version banners the release lint checks** — every
   `skein X.Y.Z` / `Skein X.Y.Z` string in `README.md` or `docs/`:
   ```bash
   grep -rEn '[Ss]kein [0-9]+\.[0-9]+\.[0-9]+' README.md docs --include='*.md' --include='*.mdx'
   ```
   Update each to `<NEW>` (these are version-display banners, e.g.
   `skein version  # → skein <NEW>` and `Skein <NEW> — AI-native …`). Do **not**
   touch the VS Code extension version (`skein-lang-…`, `v0.1.3+`) or example
   `0.1.0` data — only the `skein <version>` banners.

5. **Run the preflight** (mirrors the release workflow's gates exactly):
   ```bash
   bash "$CLAUDE_PROJECT_DIR/.claude/skills/bump-version/check-release.sh"
   ```
   It must print `Release preflight PASSED for v<NEW>`. Fix anything it flags
   (version mismatch, missing/undated changelog, drifted banner) before
   continuing — these are the exact checks that would otherwise fail the
   `Release` run after merge. If it prints a `NOTE` that the tag already exists,
   the version wasn't actually bumped — pick a new one.

6. **Branch, commit, push, and open the PR:**
   - Branch: `release/v<NEW>` (or the session's designated branch, if one is
     set — never push straight to `main`).
   - Commit: `[release] v<NEW>: bump versions, changelog, doc banners`
   - Push with `-u`, then open a PR titled `Release v<NEW>` whose body is the
     new changelog section.

7. **Hand off the last step.** Tell the user: review and merge the PR. On a green
   merge, `release.yml` tags `v<NEW>` and `build.yml` publishes the binaries, the
   VS Code extension, the docs snapshot, and the `llms*.txt` files — automatically.

## Notes

- The release gates run **post-merge** in `release.yml`; this skill's preflight
  is how you catch problems **before** merging. If you change the gate logic in
  the workflow, update `check-release.sh` to match (and vice versa).
- For a full pre-release pass (tests, gates, real binaries for all targets, a
  CLI smoke test on the built binary, docs + llms*.txt build), dispatch the
  **Release Readiness** workflow (`.github/workflows/release-readiness.yml`)
  on the bump branch or main with `expected_version: <NEW>`. It runs everything
  the post-merge flow will, without tagging or publishing anything.
- Don't create or push the `v<NEW>` tag yourself — the workflow owns tagging. A
  human-pushed tag still works (it triggers `build.yml` directly) but bypasses
  the changelog/banner gates this flow exists to enforce.
