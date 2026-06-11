# Skein Roadmap

**As of:** 2026-06-10
**Based on:** `docs/AUDIT_FIRST_PRINCIPLES.md`, the 2026-06-09 codebase audit (`docs/AUDIT_2026-06-09.md`), and a source-verified status pass on 2026-06-10.

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

Every item is self-contained and links its tracking issue — keep the two in sync when scope changes. Pick the top incomplete one and work it. Milestones: Tier 1–4 items below are the **Alpha Release** gate (repo goes public) except where their issue says otherwise; see `.github/milestones.json`.

**Every item requires:**
- TDD — tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

**Sizing key:** S = a few hours, M = half a day, L = a full day, XL = multiple days

---

## Current State

The compilation pipeline works end-to-end: lexer, parser, analyzer, codegen, and runtime are functional. **1,547 tests + 195 property tests pass** (verified against `main` CI at v0.1.5). Fourteen example programs (thirteen single-file + one multi-file) compile and run, all covered by integration tests. The LSP, CLI, docs site, and binary distribution (Burrito, four targets) are operational. v0.1.5 shipped cross-module `tool.call` end-to-end.

Most of the foundational gap-closing work from earlier roadmap revisions is **done**: real type inference for field access and pattern bindings, schema derivation for nested types and enum variants, the production Anthropic LLM backend, runtime capability enforcement for tool/LLM/topic (name- and model-aware), agent instance-scoped memory, error `context` + `fix_code` on all compiler errors, float-aware division, multi-`emit` accumulation, tool input validation, contextual (non-reserved) keywords, the persistent SQLite EventStore backend, string-literal match patterns, `store.<table>.get!/put!`, and the `queue.consume`/`schedule.trigger` capability naming.

The remaining gaps are listed below. Field-testing v0.1.5 (2026-06-10) surfaced a wave of first-five-minutes DX issues (#101, #104–#109); they are folded into the tiers below.

---

## Tier 1: Language Surface

### 2. Stream/Pool-Scoped Runtime Capability Checks `[M]`

**Issue:** [#57](https://github.com/kormie/Skein/issues/57) (enforcement; surface decided in [#69](https://github.com/kormie/Skein/issues/69))

**Problem:** `process.spawn`, `timer`, and `event.log` check capability *presence* at runtime but not parameters.

**Decision (#69, spec §3.2 "Scoped capability labels"):** the capability parameter is a scope label the compiler threads into every generated runtime call — call sites are unchanged (the `memory.kv` model). At most one declaration of each scoped kind per module/agent (E0017); a nested agent's declaration overrides the module's inside the agent; a parameterless declaration leaves the effect unscoped.

**Scope:**
- Codegen: thread the declared label into generated `process.spawn`/`timer.*`/`event.log` runtime calls (mirror the existing `memory.kv` namespace threading)
- Runtime: spawn/timer/log calls outside the declared label are blocked, mirroring the store/memory/topic/LLM/tool checks; the label lands on each trace span

**Acceptance criteria:**
- `event.log` against an undeclared stream is blocked at runtime with a structured error
- `process.spawn` against an undeclared pool is blocked at runtime
- Property: randomized capability sets permit or deny based on exact label match

---

### 3. `process.spawn` Task Bodies `[M]`

**Issue:** [#74](https://github.com/kormie/Skein/issues/74)

**Problem:** `process.spawn("name")` spawns a supervised no-op task carrying the name in its trace span. There is no way to attach actual work to the spawned process from Skein source.

**Scope:**
- Design the surface (likely `process.spawn("name", &some_fn)` with a function reference)
- Wire codegen to pass the function through to `Skein.Runtime.Process.spawn/2`, which already executes zero-arity functions under the DynamicSupervisor

**Acceptance criteria:**
- A spawned task executes a named module function in the background
- Crashes in the task don't take down the caller (already guaranteed by the supervisor; add a test from Skein source)

**Depends on:** A spec decision on the call surface.

---

### 4. Local LLM Backends for Dev (OpenAI-Compatible + `skein.toml` Profiles) `[XL]`

**Issue:** [#107](https://github.com/kormie/Skein/issues/107)

**Problem:** Testing agents means real Anthropic inference spend, and there's no way to point a project at a local model server (oMLX, Ollama, LM Studio, vLLM). Source must never change between environments — `capability model("anthropic", "claude-opus-4-8")` stays the code's contract regardless of which backend serves it.

**Scope:**
- `Skein.Runtime.Llm.OpenAiCompatibleBackend` implementing the existing `Llm.Backend` behaviour against `POST {base_url}/chat/completions`
- `[env.<name>.llm]` profiles in `skein.toml` with `model_map` remapping capability model names to locally hosted ones
- `skein run`/`skein test` resolve the active profile via `SKEIN_ENV` / `--env`; llm trace spans record which backend/base_url served each call

**Acceptance criteria:**
- `SKEIN_ENV=dev skein test` serves `llm.chat`/`llm.json` from the local server with zero source edits; plain `skein run` uses Anthropic
- Local server down → structured `Llm.Error` naming the base_url
- Stub-server tests give CI an inference-free path for agent tests

**Depends on:** Nothing.

---

## Tier 3: Polish & Developer Experience

### 5. Enum Value-Level Exhaustiveness Warning `[S]`

**Issue:** [#76](https://github.com/kormie/Skein/issues/76)

**Problem:** Exhaustiveness checking is variant-level only. `match e { Event.Charge(5) -> ... }` satisfies "Charge is covered", but `Event.Charge(10)` raises `case_clause` at runtime. (Plain literal matches without a catch-all now compile to an explicit `case_clause` raise — the gap is the missing *warning*.)

**Scope:**
- Analyzer: warn (new W code) when a variant arm uses literal field patterns and no wildcard arm exists
- See `check_exhaustiveness/4` in `analyzer.ex`

**Acceptance criteria:**
- `match e { Event.Charge(5) -> "five" }` produces a warning suggesting a wildcard arm
- Adding `_ ->` or a variable binding silences it

**Depends on:** Nothing.

---

### 6. LSP Code Actions from `fix_hint`/`fix_code` `[L]`

**Issue:** [#108](https://github.com/kormie/Skein/issues/108)

**Problem:** Every `Skein.Error` carries `fix_hint`/`fix_code` by design — the agent-writability feature — but the LSP advertises no `codeActionProvider` and drops the fix data from diagnostics, so editors show no lightbulb.

**Scope:**
- Ship `code`/`fix_hint`/`fix_code` in `Diagnostic.data`; advertise + handle `textDocument/codeAction` returning quickfixes
- Phase 1: per-code edit mapping for the mechanical wins (missing-token inserts, missing-capability line, unused-declaration deletes)
- Phase 2: extend `Skein.Error` with span + `edit_kind` so any exact fix applies generically (`skein mcp` inherits machine-applicable edits)

**Acceptance criteria:**
- Lightbulb on a missing `:` applies it; missing-capability error inserts the `capability` line; W0002 removes the declaration; errors without an applicable fix produce no action

**Depends on:** Nothing.

---

## Post-MVP Backlog

**Issue:** [#78](https://github.com/kormie/Skein/issues/78) (tracking)

Planned but not yet scoped or prioritized:

- Erlang/Elixir FFI (`extern` keyword) — interop with existing BEAM libraries
- Hot code upgrades — OTP release upgrades without downtime
- Web IDE / trace viewer — browser-based exploration of trace data
- Human-in-the-loop approval workflows — `suspend` before sensitive tool calls
- `llm.rerank` for RAG pipelines — complement the existing `llm.embed`
- An embeddings-capable LLM backend (Anthropic has no embeddings API; `llm.embed` currently needs a custom/test backend)
- Guard expressions in match arms — AST field exists but is always `nil`
- Managed deployment platform — hosted Skein runtime
- Marketplace for tools/connectors — shareable tool definitions

---

## Completed Work (Reference)

All of the following are done and tested:

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
- Capability-parameter surface decision (#69): scoped capability labels (spec §3.2) — for `memory.kv`/`event.log`/`process.spawn`/`timer` the capability parameter names a scope label the compiler threads into runtime calls (call sites unchanged); one declaration per kind per module/agent, duplicates are E0017; spec §6.11 documents the `process.spawn`/`timer` surface; runtime enforcement is item 2 (#57)
- Agent nesting inside modules (#63): `module Foo { agent Bar }` compiles to `Skein.User.Foo` + `Skein.Agent.Foo.Bar`; module types and capabilities apply to the nested agent; spec §8.4 and `market_research/single_file.skein` ship the nested shape
- Named arguments in calls (#56): `f(name: value)` for local fns and documented effect signatures; positional-then-named mixing, analyzer rewrites to positional order (E0026 for unknown/duplicate/misordered names), spec grammar + section 8 updated
- Release automation (#100, PR #102): green version-bump merges to `main` auto-tag and release (no manual tag step), README badges, per-release docs snapshots incl. `llms*.txt`; superseded PR runs cancel, main/release builds never do
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/ with `llms.txt` endpoints
- CI: format check, `--warnings-as-errors` compile, full test suite
