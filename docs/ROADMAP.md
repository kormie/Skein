# Skein Roadmap

**As of:** 2026-06-11
**Based on:** `docs/AUDIT_FIRST_PRINCIPLES.md`, the 2026-06-09 codebase audit (`docs/AUDIT_2026-06-09.md`), a source-verified status pass on 2026-06-10, and the 2026-06-11 `/release-readiness` full pass.

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

Every item is self-contained and links its tracking issue — keep the two in sync when scope changes. Pick the top incomplete one and work it. Milestones live in `.github/milestones.json` (synced by `.github/workflows/milestones.yml`); the active gate is **v1.0.0-rc Release**, followed by **v1.0.0 Release** during the rc soak.

**Every item requires:**
- TDD — tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

**Sizing key:** S = a few hours, M = half a day, L = a full day, XL = multiple days

---

## Current State

The compilation pipeline works end-to-end: lexer, parser, analyzer, codegen, and runtime are functional. **1,945 tests + 199 property tests pass** (full umbrella run, 2026-06-11 release-readiness pass). Sixteen example programs (thirteen single-file + the multi-file market_research pair and its single-file variant) compile, all covered by integration tests. The LSP, CLI, docs site, and binary distribution (Burrito, four targets) are operational. v0.3.0 shipped the complete original v1.0.0 milestone (spec freeze, guards, embeddings, Bedrock, the stability policy).

Most of the foundational gap-closing work from earlier roadmap revisions is **done**: real type inference for field access and pattern bindings, schema derivation for nested types and enum variants, the production Anthropic LLM backend, runtime capability enforcement for tool/LLM/topic (name- and model-aware), agent instance-scoped memory, error `context` + `fix_code` on all compiler errors, float-aware division, multi-`emit` accumulation, tool input validation, contextual (non-reserved) keywords, the persistent SQLite EventStore backend, string-literal match patterns, `store.<table>.get!/put!`, and the `queue.consume`/`schedule.trigger` capability naming.

The open work below comes from the 2026-06-11 **release-readiness full pass** (`/release-readiness`: build/test gates, toolchain e2e, and an adversarially verified sweep of every docs page, spec section, example, and meta-doc — every blocker confirmed by two independent verifiers). The mechanical layer was green (zero test failures); the findings are spec↔compiler contract violations, two unstructured compiler crashes, and docs-site pages that teach pre-1.0 syntax.

---

## Path to v1.0.0

The release train (each step rides the auto-tag flow — a green version-bump merge tags and publishes):

1. ~~**v0.2.0**~~ — released 2026-06-11 (Beta milestone + installer + the #114 fix)
2. ~~**v0.3.0**~~ — released 2026-06-11 (the original v1.0.0 milestone: #121 #118 #154 #147 #146 #155 #156 #157 #173 #162)
3. **v1.0.0-rc** — gated by the **v1.0.0-rc Release** milestone below: fix what the readiness pass proved broken or false, then tag
4. **v1.0.0** — the rc soaks while the **v1.0.0 Release** milestone (warning-grade findings) lands, then promote

### Milestone: v1.0.0-rc Release

The rc tags when this is empty. Spec↔compiler contract first — each is an implement-or-respec decision; everything else is mechanical:

- [#182](https://github.com/kormie/Skein/issues/182) — **bug, p1:** `transition()` outside an agent crashes codegen with a raw FunctionClauseError (also via `check_file`/MCP)
- [#183](https://github.com/kormie/Skein/issues/183) — **bug, p1:** `llm.stream` callback arg silently miscompiles to a wrong arity; decide the `on_chunk` surface
- [#184](https://github.com/kormie/Skein/issues/184) — **bug, p1:** `queue.publish` is documented but cannot be compiled (no queue effect namespace; runtime ready)
- [#185](https://github.com/kormie/Skein/issues/185) — **bug, p1:** `resume()` documented as an in-agent call but does not parse
- [#186](https://github.com/kormie/Skein/issues/186) — **bug, p1:** §5/§6 signature drift: `Instant.diff`, `Option/Result.unwrap` defaults, `process.spawn(task:)`
- [#187](https://github.com/kormie/Skein/issues/187) — **chore, p1:** §7 error-code registry incomplete and partly wrong (five missing codes, E0033, severities, §8.5 test heredoc)
- [#188](https://github.com/kormie/Skein/issues/188) — **chore, p1:** §2.3 keyword list wrong in both directions + lexical/grammar drift
- [#189](https://github.com/kormie/Skein/issues/189) — **chore, p1:** docs `language/*` pages — canonical examples don't compile, wrong error-code table, draft prose
- [#190](https://github.com/kormie/Skein/issues/190) — **chore, p1:** docs `compiler/*` pages — error-code misattributions, 3-digit codes, stale tables
- [#191](https://github.com/kormie/Skein/issues/191) — **chore, p1:** docs `runtime/*` pages — pre-1.0 agent syntax, wrong `EventStore.log` arity, stale claims
- [#192](https://github.com/kormie/Skein/issues/192) — **chore, p1:** getting-started + landing page — stub-era project tour, quickstart drift, **model id retiring 2026-06-15**
- [#193](https://github.com/kormie/Skein/issues/193) — **chore, p1:** docs `reference/*` — stdlib page teaches anonymous fns, wrong Float/Instant rows
- [#194](https://github.com/kormie/Skein/issues/194) — **chore, p1:** editor/testing/contributing pages — invented effect namespaces, stale counts, retired conventions
- [#195](https://github.com/kormie/Skein/issues/195) — **chore, p1:** CLAUDE.md presents removed surface as current (Planned escape hatch, event_log.ex)

### Milestone: v1.0.0 Release (GA gate, lands during the rc soak)

- [#196](https://github.com/kormie/Skein/issues/196) — **bug, p2:** W0001 misses string-interpolation usage (false positive with a program-breaking fix_code)
- [#197](https://github.com/kormie/Skein/issues/197) — **bug, p2:** lexer crashes on float literals with underscore grouping (`1_000.5`)
- [#198](https://github.com/kormie/Skein/issues/198) — **bug, p2:** `mix skein.compile`/`mix skein.test` print nothing and exit 0 on failure
- [#199](https://github.com/kormie/Skein/issues/199) — **chore, p2:** ship the canonical examples warning-free and honest
- [#200](https://github.com/kormie/Skein/issues/200) — **chore, p2:** meta-docs a release behind (roadmap pages, ARCHITECTURE, README, CONTRIBUTING)

### Shipped: the original v1.0.0 gate (all in v0.3.0)

- ~~[#114](https://github.com/kormie/Skein/issues/114) — **bug, p1:** Int string interpolation emits the raw codepoint~~ — fixed (PR #153), ships in v0.2.0
- ~~[#121](https://github.com/kormie/Skein/issues/121) — **bug, p1:** queue/topic handlers from compiled modules are never subscribed in a running service~~ — fixed (PR #158)
- ~~[#154](https://github.com/kormie/Skein/issues/154) — **bug, p1:** `llm.json` results decode with string keys but compiled field access reads atom keys~~ — fixed (PR #165: schema-directed key atomization at the decode boundary)
- ~~[#118](https://github.com/kormie/Skein/issues/118) — **bug, p2:** flaky CI — memory property test races shared `:skein_memory` ETS state~~ — fixed (PR #161: all named runtime ETS tables are owned by the supervised `Skein.Runtime.EtsTables`, never by transient callers)
- ~~[#147](https://github.com/kormie/Skein/issues/147) — Guard expressions in match arms — L~~ — shipped (PR #164)
- ~~[#146](https://github.com/kormie/Skein/issues/146) — Embeddings-capable LLM backend — M~~ — shipped (PR #166: OpenAI-compatible `/embeddings` proven from compiled source; Voyage AI for production via the same backend)
- ~~[#155](https://github.com/kormie/Skein/issues/155) — **chore:** Spec freeze — resolve every "Planned" annotation~~ — done (decisions recorded on the issue: timer bodies implemented, tuple destructuring + planned-testing block removed)
- ~~[#156](https://github.com/kormie/Skein/issues/156) — **chore:** Remove deprecated surface (EventLog facade + sweep)~~ — done (PR #168)
- ~~[#157](https://github.com/kormie/Skein/issues/157) — **chore:** Versioning and stability policy (`docs/STABILITY.md`)~~ — done (PR #169)

---

## Post-1.0 Backlog

**Issue:** [#78](https://github.com/kormie/Skein/issues/78) (tracking)

Everything below is post-1.0 (`.github/milestones.json`):

### Milestone: v1.1 — Hardening & Language

Well-scoped gaps with no design unknowns (the bugs and guard/embeddings work originally here moved to the v1.0.0 milestone):

- [#145](https://github.com/kormie/Skein/issues/145) — `llm.rerank` for RAG pipelines — M, depends on #146
- [#150](https://github.com/kormie/Skein/issues/150) — Code-action phase 2: `Skein.Error` span + `edit_kind` so any exact fix applies generically (phase 1 per-code mapping shipped with #108) — L

### Milestone: v1.2 — Interop & Agent Workflows

Bigger design efforts, after the hardening wave:

- [#141](https://github.com/kormie/Skein/issues/141) — Erlang/Elixir FFI (`extern` keyword) — interop with existing BEAM libraries — XL
- [#144](https://github.com/kormie/Skein/issues/144) — Human-in-the-loop approval workflows — `suspend` before sensitive tool calls — XL
- [#143](https://github.com/kormie/Skein/issues/143) — Web trace viewer — browser-based exploration of trace data — L–XL
- [#171](https://github.com/kormie/Skein/issues/171) — CLI TUI — adopt a terminal UI framework for interactive trace/test/run (options researched in the issue; TermUI leading, Burrito compatibility is the gating spike) — XL

### Milestone: Future — Platform

Deliberately deferred (per CLAUDE.md "What Not To Do"); re-scope from scratch when pulled into active work:

- [#142](https://github.com/kormie/Skein/issues/142) — Hot code upgrades — OTP release upgrades without downtime
- [#148](https://github.com/kormie/Skein/issues/148) — Managed deployment platform — hosted Skein runtime
- [#149](https://github.com/kormie/Skein/issues/149) — Marketplace for tools/connectors — shareable tool definitions

---

## Completed Work (Reference)

All of the following are done and tested:

- Spec freeze (#155): zero "Planned" annotations remain — timer task bodies implemented (`timer.after/interval(..., "task", &fn)` runs the fn in a supervised task per fire); tuple destructuring and the planned-testing block removed from the 1.0 spec (decisions recorded on the issue)
- llm.json key atomization (#154), llm.embed production path (#146), deprecated-surface removal (#156), stability policy docs/STABILITY.md (#157)

- Guard expressions in match arms (#147): `pattern if expr -> body` with contextual `if`; guards type-check as Bool with pattern bindings in scope and are restricted to a guard-safe subset (E0027 otherwise — no calls/effects/division/interpolation); guarded arms don't count toward exhaustiveness (analyzer + codegen catch-all); lowered to Core Erlang clause guards in module and agent paths; property pins compiled output to reference semantics
- Queue/topic handler subscription at server startup (#121): `Server.init/1` registers all background handlers from `__handlers__/0` — schedule registers, queue/topic subscribe — so compiled handlers receive published messages in a running service
- ETS table ownership (#118): all named runtime tables are created by the supervised `Skein.Runtime.EtsTables` owner (first child; unlinked `--no-start` fallback), fixing the class of flakes where a table died with the transient process that first touched it
- Int/Float/Bool string interpolation (#114): interpolation segments coerce at runtime — Ints render decimal digits, Floats use the `:short` format, Bools render `true`/`false`; binaries pass through unchanged

- Phases 1–7: full compilation pipeline (lexer, parser, analyzer, codegen)
- Phase 8a–8f: test infrastructure, Ecto/SQLite storage, HTTP server (Bandit + Plug), canonical examples, queue/schedule handlers, LLM streaming
- Phase 10: unified event store (+ optional persistent SQLite backend)
- Cross-module `tool.call` end-to-end (v0.1.5): `implement` blocks compile to exported entry points, CLI registers tools at module load; tools are the only cross-module seam (E0016 rejects cross-module function calls)
- Expression-position variant construction, call forms (v0.1.5): `Ok(x)`, `Err(e)`, `Event.Charge(n)`, `ErrName.from(cause)` — zero-field forms tracked in item 4
- Prefix unary minus; targeted parser errors for known names missing their token (v0.1.5)
- Agent context injection (v0.1.5): `skein new` scaffolds AGENTS.md, `skein agents` regenerates it, `skein mcp` serves spec lookup/docs search/compile checks over stdio
- Two-phase `skein test` runner (compile + load all of src/ and test/, then run); `skein new` scaffolds co-located tests + a cross-module integration test
- Type inference: field access through user-defined types, pattern bindings carry `Result`/variant inner types
- Schema derivation: nested user types, enum `oneOf`, `Map[K, V]` `additionalProperties`, circular-reference safety
- Production LLM backend: Anthropic Messages API (chat, json, stream) with retry and structured errors; current model IDs throughout
- Runtime capability enforcement: store, memory, HTTP, topic (name-scoped), tool (tool-name-scoped), LLM (model-scoped), presence checks for process/timer/event.log
- Agent instance-scoped memory (`{agent}:{instance}:{key}`)
- Error system: 22 error + 3 warning codes aligned with the spec; `context` and `fix_code` populated everywhere
- Codegen correctness: float-aware division, multi-`emit` accumulation, string-literal match patterns, explicit non-exhaustive-match failure clauses, `state.field` in nested positions, `method!(args)`/`method?(args)` parsing, `store.get!/put!`
- Tool input validation against generated JSON Schema (`validation_error`)
- Contextual keywords un-reserved (12 tokens usable as identifiers outside their construct)
- `queue.consume` / `schedule.trigger` capability naming (old names get a targeted rename hint)
- Standard library: 11 modules, 101 functions
- suspend/resume, respond.text/html, topic pub/sub, idempotent(key), trace.annotate, llm.embed, process.spawn, timer, event.log
- LSP: completions, hover, diagnostics, semantic tokens, document symbols, go-to-definition (+ request/response integration tests)
- CLI: new, build (`--output`), test, run, trace; structured errors for malformed flags
- Distribution: Burrito binaries (Linux x86_64/ARM64, macOS x86_64/ARM64), GitHub Release automation on `v*` tags
- Spec section 8 sweep (#77): every section-8 example now COMPILES with zero diagnostics (spec_examples_test upgraded from parse-only to full check_file); 8.4's phase machine fixed (Analyze -> Failed declared, Done handler added); effect error types from spec section 6 (HttpError, StoreError, NotFound, ...) registered as known type names; store.<table> usage now counts for W0002; tuple destructuring annotated Planned in the grammar
- zsh tab-completion (#101): `skein completions zsh` prints the script (subcommands + descriptions, per-command flags, .skein/directory positionals, trace --kind span kinds); drift test pins completions to the help text; README install snippet
- MCP `skein_compile_check` fidelity (#109): new `Compiler.check_file/1` returns errors AND warnings (full pipeline, no load); MCP result schema gains `warnings` (ok stays errors-only); project mode checks `src/` and `test/` like `skein test`
- Assertion failures show expected vs actual + location (#105): failing asserts raise structured Skein.Runtime.AssertionError (op/left/right/rendered expr/file:line); comparison operands bound and reported; CLI FAIL lines print the location; scenario/golden inherit via the shared lowering
- `skein new` git init + `.gitignore` (#106): cargo-style — init by default (skipped inside an existing work tree, with --no-git, or when git is missing), baseline .gitignore always written
- Agent `emit` -> EventStore (#72): handler-emitted events flush to the EventStore as :user_event (tagged agent/instance_id/phase) BEFORE the result is acted on, so they survive crashes; get_events/1 still reads gen_statem data; property pins N emits across M transitions = N stored events
- Schedule handler auto-firing (#71): periodic tick (1s, configurable) evaluates full 5-field cron matching (`*`, `n`, `a-b`, `*/n`, lists; DOM/DOW OR rule) with per-minute dedup; `Server` registers `:schedule` handlers from `__handlers__/0`; invalid crons rejected at registration; deterministic `tick_at/1` + firing-count property for tests
- Capability checks cover test blocks (#104): test/scenario/golden bodies feed both capability passes — effects inside tests require capabilities (E0012) and count as usage (no W0002 on the `skein new` scaffold; pinned by a scaffold-analyzes-warning-free CLI test)
- Enum variant construction completeness (#96): zero-field variants construct in expression position (`Status.Active`, bare `Active`, `Status.Active()` — all lower to `:active`, matching patterns); unknown variants and wrong constructor arity/types are structured E0010/E0020 with closest-name fix_code (no core_lint crashes remain)
- Types usable from agents (#70): module types are visible to nested agents and the derived JSON Schema flows into `llm.json[T]` requests from agent handlers (verified via recording backend); agents never declare their own `type` blocks — nesting is the route (spec §3.7)
- Replay backend injection (#73): an active `Replay.with_replay/2` context intercepts LLM (via `Llm.ReplayBackend`), HTTP, and tool-call effects, serving recorded responses with zero real calls; recorded events are validated against the live call (model/method/url/tool name) so out-of-sequence runs produce clear errors; LLM/HTTP/tool spans now record full response payloads (`response`, `response_body`/`status`) so live traces are replayable; replay state stays process-scoped
- Capability-parameter surface decision (#69): scoped capability labels (spec §3.2) — for `memory.kv`/`event.log`/`process.spawn`/`timer` the capability parameter names a scope label the compiler threads into runtime calls (call sites unchanged); one declaration per kind per module/agent, duplicates are E0017; spec §6.11 documents the `process.spawn`/`timer` surface
- Stream/pool-scoped runtime capability enforcement (#57): codegen threads the declared label into `process.spawn`/`timer.*`/`event.log` runtime calls (the `memory.kv` model); the shared `Capability.check_scoped/3` blocks calls outside the declared label (parameterless declarations stay presence-only); labels land on trace spans (`pool:`/`group:`) and stored events (`stream:`); `timer.after`/`timer.interval` now accept string task names as named no-ops; property pins permit/deny on exact label match over randomized capability sets
- `process.spawn` task bodies (#74): `process.spawn("name", &some_fn)` runs the referenced zero-parameter local fn inside the supervised task (spec §6.11); `work` is the first optional effect parameter (named-arg resolver supports trailing optionals); crashes stay isolated by the supervisor, proven from compiled Skein source; timer task bodies remain Planned
- Local LLM backends for dev (#107): `Skein.Runtime.Llm.OpenAiCompatibleBackend` speaks `POST {base_url}/chat/completions` (oMLX/Ollama/LM Studio/llama.cpp/vLLM); `[llm]` + `[env.<name>.llm]` profiles in skein.toml with `model_map` remapping capability model names (source and capabilities never change between environments); `skein run`/`skein test` resolve `--env`/`SKEIN_ENV`; llm spans record `backend`/`base_url`; server-down is a structured LlmError naming the base_url; stub-server tests give CI an inference-free path; docs page runtime/local-models
- LSP code actions from `fix_hint`/`fix_code` (#108, phase 1): diagnostics ship `code`/`fix_hint`/`fix_code` in `Diagnostic.data`; `codeActionProvider` advertised and `textDocument/codeAction` answers from the diagnostic alone — missing-token inserts (E0001), missing-capability line insertion (E0012, after the last capability or the module opening), unused-capability line deletion (W0002), unused-binding underscore rename (W0001); unmapped codes produce no action; phase 2 (error spans + edit_kind) moved to the backlog
- Enum value-level exhaustiveness warning (#76): new W0004 when a variant arm uses literal field patterns and no wildcard or all-bindings arm covers the variant; enum-typed fn params now reach exhaustiveness checking at all (previously `{:user_type, ...}` skipped it), and dotted variant patterns (`Event.Charge(n)`) count as coverage instead of false-missing
- Agent nesting inside modules (#63): `module Foo { agent Bar }` compiles to `Skein.User.Foo` + `Skein.Agent.Foo.Bar`; module types and capabilities apply to the nested agent; spec §8.4 and `market_research/single_file.skein` ship the nested shape
- Named arguments in calls (#56): `f(name: value)` for local fns and documented effect signatures; positional-then-named mixing, analyzer rewrites to positional order (E0026 for unknown/duplicate/misordered names), spec grammar + section 8 updated
- Release automation (#100, PR #102): green version-bump merges to `main` auto-tag and release (no manual tag step), README badges, per-release docs snapshots incl. `llms*.txt`; superseded PR runs cancel, main/release builds never do
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/ with `llms.txt` endpoints
- CI: format check, `--warnings-as-errors` compile, full test suite
