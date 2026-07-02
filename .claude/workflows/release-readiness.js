export const meta = {
  name: 'release-readiness',
  description: 'Full pre-release pass: build/test gates, toolchain e2e, and an adversarially-verified docs/spec/examples sweep',
  whenToUse: 'Before cutting a release tag (built for the v1.0.0-rc gate). Optionally pass the version you intend to ship, e.g. /release-readiness 1.0.0-rc.1',
  phases: [
    { title: 'Gates', detail: 'format, compile, full test suite, release preflight, toolchain e2e' },
    { title: 'Inventory', detail: 'enumerate every docs page, spec section, example, and meta-doc' },
    { title: 'Sweep', detail: 'one auditor per unit, hunting release blockers' },
    { title: 'Verify', detail: 'independent adversarial check of every finding' },
    { title: 'Synthesize', detail: 'merge into a go / no-go report' },
  ],
}

// Optional arg: the version you intend to ship (e.g. "1.0.0-rc.1").
const TARGET_VERSION =
  (typeof args === 'string' ? args.trim().replace(/^v/, '') : '') || null

const MAX_UNITS = 100
const MAX_FINDINGS_PER_UNIT = 5

// ─── Shared context every subagent gets (they start blank) ───
const REPO_CONTEXT =
  'You are part of a release-readiness audit of the Skein repository (an Elixir umbrella ' +
  'implementing the Skein language: compiler, runtime, CLI, LSP), run before cutting a ' +
  (TARGET_VERSION ? 'v' + TARGET_VERSION : 'release') + ' tag. Work from the repository root.\n' +
  'Ground rules for judging:\n' +
  '- The currently shipping version is `version:` in the root mix.exs (apps/skein_cli/mix.exs must agree).\n' +
  '- "skein X.Y.Z" / "Skein X.Y.Z" banner strings in README.md and docs/ must match the root mix.exs ' +
  'version exactly (CHANGELOG.md is exempt; the VS Code extension has its own version; example data like "0.1.0" is not a banner).\n' +
  '- Surface REMOVED for 1.0 must not be presented as current anywhere: the Skein.Runtime.EventLog facade ' +
  '(use EventStore), tuple destructuring (`let (a, b) = ...`), and the planned-testing block ' +
  '(Agent.run_sync(), stub declarations, agent.events / agent.final_phase, anonymous fns). ' +
  'LSP annotation completions are exactly the implemented spec 4.2 set (no @pattern/@optional/@deprecated).\n' +
  '- The spec is FROZEN for 1.0: no "Planned" annotations may remain in docs/SKEIN_SPEC.md.\n' +
  '- Useful commands: `mix skein.compile path/to/file.skein` compiles one file; ' +
  '`bash .claude/skills/bump-version/check-release.sh` is the release preflight; tests run with `mix test`.\n' +
  'Severity ladder — be strict about it:\n' +
  '- blocker: would ship something broken or false in the release (failing build/tests, a doc or example ' +
  'that demonstrates removed/unimplemented surface, a broken canonical example, a gate release.yml would fail on).\n' +
  '- warning: should be fixed but does not gate the tag (stale-but-harmless prose, a shipped feature missing from docs).\n' +
  '- info: worth a note, no action required.\n'

// ─── Schemas ───
const GATES_SCHEMA = {
  type: 'object', required: ['gates', 'summary'],
  properties: {
    gates: { type: 'array', items: {
      type: 'object', required: ['name', 'status', 'detail'],
      properties: {
        name: { type: 'string' },
        status: { enum: ['pass', 'fail', 'blocked'] },
        detail: { type: 'string' },
      },
    }},
    summary: { type: 'string' },
  },
}

const UNITS_SCHEMA = {
  type: 'object', required: ['units'],
  properties: {
    units: { type: 'array', items: {
      type: 'object', required: ['kind', 'target'],
      properties: {
        kind: { enum: ['docs-page', 'spec-section', 'example', 'meta-doc'] },
        target: { type: 'string' },
        note: { type: 'string' },
      },
    }},
  },
}

const FINDINGS_SCHEMA = {
  type: 'object', required: ['findings'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', required: ['severity', 'file', 'summary', 'evidence'],
      properties: {
        severity: { enum: ['blocker', 'warning', 'info'] },
        file: { type: 'string' },
        line: { type: 'number' },
        summary: { type: 'string' },
        evidence: { type: 'string' },
        fix_hint: { type: 'string' },
      },
    }},
  },
}

const VERDICT_SCHEMA = {
  type: 'object', required: ['verdict', 'evidence'],
  properties: {
    verdict: { enum: ['CONFIRMED', 'REFUTED'] },
    evidence: { type: 'string' },
  },
}

// ─── Prompts ───
const GATES_PROMPT =
  REPO_CONTEXT +
  '\nRun the mechanical release gates from the repository root, in order, and report each as a ' +
  'gate entry (status pass/fail; use "blocked" only when the environment prevents the check, e.g. ' +
  'hex.pm unreachable for deps — never to soften a real failure). Capture the decisive output ' +
  'lines in detail (e.g. test totals, the failing test names, the preflight error).\n\n' +
  '1. `mix deps.get` (blocked if the network prevents it — then mark the dependent gates blocked too)\n' +
  '2. `mix format --check-formatted`\n' +
  '3. `mix compile --warnings-as-errors`\n' +
  '4. `mix test` (the full umbrella suite; record the totals line)\n' +
  '5. `bash .claude/skills/bump-version/check-release.sh` (release preflight: version agreement, dated CHANGELOG, banner drift)\n' +
  '6. Freeze gates (#332): from each app directory run its freeze suite and report one gate entry per app — ' +
  '`cd apps/skein_compiler && mix test test/skein/freeze` (keywords, diagnostics registry, effect ABI, ' +
  'JSON Schema vectors, metadata classes), `cd apps/skein_runtime && mix test test/skein/runtime/event_store_freeze_test.exs` ' +
  '(persisted event vectors), `cd apps/skein_cli && mix test test/cli/cli_surface_freeze_test.exs test/cli/dogfood_pins_freeze_test.exs` ' +
  '(CLI/config surface, dogfood pins). These compare the live surfaces against the frozen vectors in ' +
  'conformance/freeze/ — a failure means a frozen surface drifted and the release CANNOT be GO.\n' +
  (TARGET_VERSION
    ? '7. Version staging for the intended release v' + TARGET_VERSION + ': the `version:` in BOTH mix.exs and ' +
      'apps/skein_cli/mix.exs must equal "' + TARGET_VERSION + '" (fail with what they actually say if not — ' +
      'that means the bump PR has not landed), and `git ls-remote --tags origin refs/tags/v' + TARGET_VERSION + '` ' +
      'must come back empty (fail if the tag already exists).\n'
    : '') +
  '\nStructured output only.'

const E2E_PROMPT =
  REPO_CONTEXT +
  '\nExercise the Skein toolchain end-to-end through the Mix aliases, like a user would. ' +
  'Report each step as a gate entry (pass/fail/blocked) with decisive output in detail.\n\n' +
  '1. Scaffold: `mix skein.new /tmp/skein_rc_smoke` (delete that directory first if it exists)\n' +
  '2. Test the scaffold: `mix skein.test /tmp/skein_rc_smoke` — must report 0 failed\n' +
  '3. Compile every canonical example: every file matched by `examples/*.skein` and ' +
  '`examples/market_research/*.skein`, each via `mix skein.compile <file>`. One gate entry ' +
  'per FAILING example (name the file); one summary entry for the ones that passed (count them).\n' +
  '4. Dogfood gate (#262): run `mix skein.test conformance/dogfood/<name>` for every project ' +
  'directory under conformance/dogfood/ — each must report 0 failed and 0 compile failures, ' +
  'and the total per project must equal its `expected_tests` in conformance/dogfood.json. ' +
  'One gate entry per project. Release-readiness CANNOT report GO without these.\n' +
  '5. Agent-writability benchmark (#320): `mix skein.bench -- --report /tmp/skein_bench_report.json` ' +
  '(replay mode — deterministic, no LLM calls) — must exit 0 with every task green. Put the ' +
  'first-try compile rate and mean-iterations-to-green from the printed summary in detail: ' +
  'they are the measured RC writability quality. Clean up the report file.\n' +
  '6. Clean up /tmp/skein_rc_smoke.\n' +
  '\nStructured output only.'

const INVENTORY_PROMPT =
  REPO_CONTEXT +
  '\nEnumerate the audit surface for the documentation/spec/examples sweep. Do NOT audit anything ' +
  'yourself — just build the work list:\n\n' +
  '- kind "docs-page": every .md/.mdx file under docs/site/src/content/docs/ (target = path)\n' +
  '- kind "spec-section": every top-level `## ` section of docs/SKEIN_SPEC.md ' +
  '(target = "docs/SKEIN_SPEC.md <heading text>")\n' +
  '- kind "example": every .skein file under examples/ including subdirectories (target = path)\n' +
  '- kind "meta-doc": exactly these, when they exist: README.md, CHANGELOG.md, docs/ROADMAP.md, ' +
  'docs/STABILITY.md, docs/ARCHITECTURE.md, CONTRIBUTING.md, CLAUDE.md, examples/README.md (target = path)\n' +
  '\nUse note for anything an auditor of that unit should know (e.g. "multi-file example, agent half"). ' +
  'Structured output only.'

const sweepChecklist = {
  'docs-page':
    'Audit this published documentation page for release blockers:\n' +
    '- Claims must match the current implementation — spot-check anything load-bearing against the ' +
    'compiler/runtime source or tests rather than trusting prose.\n' +
    '- Code snippets: full programs should compile (write to a temp .skein file, `mix skein.compile` it, ' +
    'clean up); fragments get checked against the spec grammar and analyzer behavior.\n' +
    '- No removed surface presented as current; no feature promised that is not implemented.\n' +
    '- Version banners must match the root mix.exs version.',
  'spec-section':
    'Audit this section of the frozen language specification:\n' +
    '- No "Planned" annotations may remain anywhere in the section.\n' +
    '- Spot-check normative claims (grammar, error codes, effect signatures) against the parser/analyzer/' +
    'codegen source and tests. The error-code table must agree with what the compiler actually emits.\n' +
    '- Section 8 example programs must compile (spec_examples_test.exs enforces this — run the relevant ' +
    'test if in doubt: `mix test apps/skein_compiler/test/skein/spec_examples_test.exs`).\n' +
    '- Internal cross-references and the one-way-to-do-things rule hold.',
  'example':
    'Audit this canonical example program:\n' +
    '- It must compile with zero errors via `mix skein.compile <file>`; treat analyzer warnings as a warning finding.\n' +
    '- It must use only current surface (no removed constructs) and demonstrate what the ' +
    'examples/README.md index says it demonstrates.\n' +
    '- Model names in capability declarations must be current (never claude-sonnet-4-20250514).',
  'meta-doc':
    'Audit this repository document for release readiness:\n' +
    '- README.md: install instructions, banners, badges, and feature claims must be true today.\n' +
    '- CHANGELOG.md: the Unreleased section must cover the work merged since the last release ' +
    '(`git log --no-merges v<last-release>..HEAD --pretty=%s` — find the last release tag with ' +
    '`git tag --sort=-v:refname | head`); flag shipped-but-undocumented work as warning.\n' +
    '- docs/ROADMAP.md: every v1.0.0-milestone item must be marked done; the release train must reflect reality.\n' +
    '- docs/STABILITY.md: stability classes must match the actual public surfaces.\n' +
    '- CLAUDE.md / CONTRIBUTING.md: structure trees, commands, and workflow descriptions must be accurate.\n' +
    '- For other docs: same standard — nothing false, nothing promising unshipped work.',
}

const sweepPrompt = (u) =>
  REPO_CONTEXT +
  '\nYour single audit unit (kind: ' + u.kind + '):\n  ' + u.target +
  (u.note ? '\n  Note: ' + u.note : '') + '\n\n' +
  sweepChecklist[u.kind] + '\n\n' +
  'Read the unit fully. Verify against the actual code/tests — an auditor who only read the prose has ' +
  'not audited. Return at most ' + MAX_FINDINGS_PER_UNIT + ' findings, most severe first, each with the ' +
  'file (and line when you have one), a one-line summary, concrete evidence (quote the offending text / ' +
  'command output), and a fix_hint. An empty findings list means the unit is clean — that is a fine ' +
  'answer; do not invent findings. Structured output only.'

const verifyPrompt = (f, u) =>
  REPO_CONTEXT +
  '\nAdversarially verify one finding from the sweep (audit unit: ' + u.target + '). Try to REFUTE it.\n\n' +
  'Finding (' + f.severity + '): ' + f.summary + '\n' +
  'File: ' + f.file + (f.line != null ? ':' + f.line : '') + '\n' +
  'Evidence given: ' + f.evidence + '\n\n' +
  'Independently re-check the claim against the repository — read the file, run the command, check the ' +
  'source. CONFIRMED only if the problem is real as stated for the version currently in mix.exs; ' +
  'REFUTED if it is wrong, already fixed, out of scope for a release gate (e.g. CHANGELOG history, ' +
  'extension version, example data), or not actually what the cited text says. When uncertain, REFUTED. ' +
  'Evidence must quote or cite what you checked. Structured output only.'

// ─── Phase 1+2 run concurrently: mechanical gates, and inventory→sweep→verify ───
const failuresOf = (g) => (g && g.gates ? g.gates.filter((x) => x.status === 'fail') : [])
const blockedOf = (g) => (g && g.gates ? g.gates.filter((x) => x.status === 'blocked') : [])

const [mechanical, sweep] = await parallel([
  // Thunk A: gates, then (if the tree builds) the toolchain e2e — sequential, shared _build.
  async () => {
    const gates = await agent(GATES_PROMPT, { label: 'gates', phase: 'Gates', schema: GATES_SCHEMA })
    const buildBroken =
      !gates || failuresOf(gates).some((x) => /deps|compile/i.test(x.name))
    if (buildBroken) {
      log('build gates failed — skipping the toolchain e2e')
      return { gates, e2e: null }
    }
    const e2e = await agent(E2E_PROMPT, { label: 'toolchain-e2e', phase: 'Gates', schema: GATES_SCHEMA })
    return { gates, e2e }
  },

  // Thunk B: inventory, then a per-unit sweep with adversarial verification (no barrier between units).
  async () => {
    const inv = await agent(INVENTORY_PROMPT, { label: 'inventory', phase: 'Inventory', schema: UNITS_SCHEMA })
    if (!inv || !inv.units || inv.units.length === 0) {
      return { unitCount: 0, confirmed: [], refuted: [], infos: [] }
    }
    let units = inv.units.filter((u) => sweepChecklist[u.kind])
    if (units.length > MAX_UNITS) {
      log('capping sweep at ' + MAX_UNITS + ' of ' + units.length + ' units (dropped: ' +
        units.slice(MAX_UNITS).map((u) => u.target).join(', ') + ')')
      units = units.slice(0, MAX_UNITS)
    }
    log('sweeping ' + units.length + ' units')

    const perUnit = await pipeline(
      units,
      (u) => agent(sweepPrompt(u), {
        label: 'sweep: ' + u.target.replace(/^docs\/site\/src\/content\/docs\//, ''),
        phase: 'Sweep',
        schema: FINDINGS_SCHEMA,
      }),
      async (res, u) => {
        if (!res || !res.findings || res.findings.length === 0) return { confirmed: [], refuted: [], infos: [] }
        const findings = res.findings.slice(0, MAX_FINDINGS_PER_UNIT).map((f) => ({ ...f, unit: u.target }))
        const significant = findings.filter((f) => f.severity !== 'info')
        const infos = findings.filter((f) => f.severity === 'info')
        const confirmed = []
        const refuted = []
        // Blockers get two independent refuters (drop only if both refute; one refutation
        // downgrades to a contested warning). Warnings get one refuter.
        const checks = await parallel(significant.map((f) => async () => {
          const n = f.severity === 'blocker' ? 2 : 1
          const votes = (await parallel(
            Array.from({ length: n }, (_, i) => () =>
              agent(verifyPrompt(f, u), {
                label: 'verify[' + (i + 1) + '/' + n + ']: ' + f.summary.slice(0, 50),
                phase: 'Verify',
                schema: VERDICT_SCHEMA,
              }))
          )).filter(Boolean)
          const confirms = votes.filter((v) => v.verdict === 'CONFIRMED').length
          if (votes.length === 0) return { ...f, verdict: 'UNVERIFIED' }
          if (confirms === 0) return { ...f, verdict: 'REFUTED', refutation: votes[0].evidence }
          if (f.severity === 'blocker' && confirms < votes.length) {
            return { ...f, severity: 'warning', contested: true, verdict: 'CONFIRMED' }
          }
          return { ...f, verdict: 'CONFIRMED' }
        }))
        for (const c of checks.filter(Boolean)) {
          if (c.verdict === 'REFUTED') refuted.push(c)
          else confirmed.push(c)
        }
        return { confirmed, refuted, infos }
      }
    )

    const merged = { unitCount: units.length, confirmed: [], refuted: [], infos: [] }
    for (const r of perUnit.filter(Boolean)) {
      merged.confirmed.push(...(r.confirmed || []))
      merged.refuted.push(...(r.refuted || []))
      merged.infos.push(...(r.infos || []))
    }
    return merged
  },
])

// ─── Synthesize ───
phase('Synthesize')

const gates = mechanical ? mechanical.gates : null
const e2e = mechanical ? mechanical.e2e : null
const gateFailures = [...failuresOf(gates), ...failuresOf(e2e)]
const gateBlocked = [...blockedOf(gates), ...blockedOf(e2e)]
const blockers = (sweep ? sweep.confirmed : []).filter((f) => f.severity === 'blocker')
const warnings = (sweep ? sweep.confirmed : []).filter((f) => f.severity === 'warning')

const verdict =
  gateFailures.length > 0 || blockers.length > 0 ? 'NO_GO'
  : !gates || !sweep || gateBlocked.length > 0 ? 'INCONCLUSIVE'
  : 'GO'

const resultData = {
  verdict,
  target_version: TARGET_VERSION,
  gates: gates ? gates.gates : null,
  toolchain_e2e: e2e ? e2e.gates : null,
  blockers,
  warnings,
  infos: sweep ? sweep.infos : [],
  refuted_count: sweep ? sweep.refuted.length : 0,
  units_swept: sweep ? sweep.unitCount : 0,
}

const report = await agent(
  REPO_CONTEXT +
  '\nWrite the final release-readiness report from this audit data (JSON below). Markdown, for the ' +
  'maintainer deciding whether to cut ' + (TARGET_VERSION ? 'v' + TARGET_VERSION : 'the release') + ':\n' +
  '- Lead with the verdict line: ' + verdict + ' (do not soften it).\n' +
  '- Gates table (mechanical + toolchain e2e), then blockers with fix hints, then warnings, then a ' +
  'one-line count of infos and refuted findings.\n' +
  '- End with next steps: on GO, prepare the bump PR (the bump-version skill) and merge on green; on ' +
  'NO_GO, the fix list in priority order; on INCONCLUSIVE, what was blocked and how to re-run.\n' +
  '- Report only what is in the data — no new claims.\n\n' +
  JSON.stringify(resultData),
  { label: 'report', phase: 'Synthesize' }
)

return {
  verdict,
  target_version: TARGET_VERSION,
  blockers,
  warnings,
  stats: {
    units_swept: resultData.units_swept,
    gate_failures: gateFailures.length,
    gates_blocked: gateBlocked.length,
    infos: resultData.infos.length,
    refuted: resultData.refuted_count,
  },
  report: report || '(report agent returned nothing — see structured fields)',
}
