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

### 1. Schedule Handler Auto-Firing `[M]`

**Issue:** [#71](https://github.com/kormie/Skein/issues/71)

**Problem:** Schedule handlers register their cron expression but never fire automatically — only manual `Schedule.trigger/1` works. A `handler schedule "*/5 * * * *"` does nothing in a running service.

**Scope:**
- Periodic tick (e.g. `:timer.send_interval/2` at 1s granularity) in `Skein.Runtime.Schedule`
- Evaluate registered cron expressions on each tick; fire matching handlers via the existing dispatch path
- Track last-fired time per handler to prevent duplicate firing within a cron period

**Acceptance criteria:**
- A registered `* * * * *` handler fires once per minute without manual intervention
- `trigger/1` still works for tests
- No duplicate firings within the same cron period
- Property: for any valid cron expression and time window, firing count matches the expected count

**Depends on:** Nothing.

---

### 2. Agent `emit` Events to EventStore `[M]`

**Issue:** [#72](https://github.com/kormie/Skein/issues/72)

**Problem:** Events emitted inside agents accumulate in `gen_statem` data but are never appended to the EventStore. If the agent crashes, emitted events are lost, and `EventStore.query/1` can't see agent events.

**Scope:**
- After each phase handler completes in `Skein.Runtime.Agent`, flush accumulated events to `EventStore.append/1`, tagged with agent name, instance ID, and phase
- `Agent.get_events/1` keeps reading from `gen_statem` data (hot path); the EventStore is the durable record

**Acceptance criteria:**
- After an agent emits and transitions, `EventStore.query(kind: :user_event)` includes those events
- Events emitted before a crash survive in the EventStore
- Property: N events across M transitions ⇒ exactly N events in the EventStore

**Depends on:** Nothing.

---

### 3. Replay Backend Injection `[L]`

**Issue:** [#73](https://github.com/kormie/Skein/issues/73)

**Problem:** `Skein.Runtime.Replay` can load traces, rebuild memory, and holds replay state (`with_replay/2`, `next_response/1`), but the LLM/HTTP/tool runtimes never consult it — `Llm.chat` always calls the configured backend. Recorded-mode replay therefore can't actually intercept live effects.

**Scope:**
- LLM: when replay state is active for the current process, return the recorded response instead of calling the backend (a `ReplayBackend` implementing the `Backend` behaviour is the cleanest route)
- HTTP and tool calls: same interception via their dispatch paths
- Out-of-sequence events produce a clear error, not a silent mismatch

**Acceptance criteria:**
- Given a recorded trace, replaying an agent run produces identical results with zero real LLM/HTTP calls
- Replay state is process-scoped — concurrent replays don't contaminate each other
- `load_trace/1` and `rebuild_memory/2` continue to work unchanged

**Depends on:** Nothing.

---

### 4. Stream/Pool-Scoped Runtime Capability Checks `[M]` *(needs surface design first)*

**Issues:** [#69](https://github.com/kormie/Skein/issues/69) (surface decision), [#57](https://github.com/kormie/Skein/issues/57) (enforcement)

**Problem:** `process.spawn`, `timer`, and `event.log` check capability *presence* at runtime but not parameters. Full enforcement is blocked on a language-surface question: the capability parameter names a pool/stream label (`capability event.log("audit")`), while the runtime call carries a different value (the event name: `event.log("user.login", data)`), so there is nothing to match the declared label against at the call site.

**Scope:**
- Decide the surface: either effect calls carry the stream/pool explicitly (`event.log("audit", "user.login", data)`), or the compiler threads the declared label into the generated runtime call
- Then enforce: spawn/timer/log calls outside the declared label are blocked at runtime, mirroring the store/memory/topic/LLM/tool checks

**Acceptance criteria:**
- `event.log` against an undeclared stream is blocked at runtime with a structured error
- `process.spawn` against an undeclared pool is blocked at runtime
- Property: randomized capability sets permit or deny based on exact label match

**Depends on:** A spec decision (keep the spec ≤128K tokens in mind).

---

### 5. `process.spawn` Task Bodies `[M]`

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

### 6. Local LLM Backends for Dev (OpenAI-Compatible + `skein.toml` Profiles) `[XL]`

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

### 7. Test Failures Show Expected vs Actual + Location `[M]`

**Issue:** [#105](https://github.com/kormie/Skein/issues/105)

**Problem:** A failing `assert` prints only "Assertion failed" — no operands, no `file:line`. Codegen lowers `__assert__` to a single boolean and raises a constant `RuntimeError`, discarding the operands and the meta location the parser already carries. The failure message is also what a coding agent debugs from.

**Scope:**
- New structured `Skein.Runtime.AssertionError` (`op`, `left`, `right`, `expr`, `file`, `line`)
- Codegen special-cases `__assert__` over comparison `BinaryOp`s: bind operands, raise with both inspected values + location; bare truthy asserts keep location
- CLI FAIL lines print `file:line` and left/right

**Acceptance criteria:**
- `assert a == b` failure shows inspected left and right values and the assert's `file:line`
- Scenario `expect` and golden tests inherit the output via the shared `__test_N__` lowering

**Depends on:** Nothing.

---

### 8. MCP `skein_compile_check` Fidelity `[M]`

**Issue:** [#109](https://github.com/kormie/Skein/issues/109)

**Problem:** The MCP tool reports clean on projects `skein test` visibly flags: `compile_file/1` discards analyzer warnings before the tool sees them, and project mode globs only `src/**/*.skein` — `test/` (where the scaffold's integration test lives) is never compiled.

**Scope:**
- A warnings-preserving compile API shared with the LSP diagnostics path (not a third reimplementation)
- Result schema gains `warnings` (each entry keeps `code`/`severity`/`message`/`location`/`fix_hint`/`fix_code`); `ok` stays errors-only
- Project mode globs `src/**` and `test/**`, matching `skein test` discovery

**Acceptance criteria:**
- On a fresh scaffold (pre-item-5 fix), project-mode `compile_check` reports `files_checked: 2` and the W0002 with its location

**Depends on:** Nothing (pairs naturally with item 5).

---

### 9. `skein new` Git Init + Baseline `.gitignore` `[S]`

**Issue:** [#106](https://github.com/kormie/Skein/issues/106)

**Problem:** The scaffold ships without version control, and the first `git add .` after `skein build --output` drags `.beam`/`_build` artifacts (and eventually `erl_crash.dump`) into the repo.

**Scope:** cargo-style `git init` by default (skipped inside an existing work tree, when `git` is missing, or with `--no-git`); always write a baseline `.gitignore` (build artifacts, crash dumps, local SQLite state); no auto-commit.

**Depends on:** Nothing.

---

### 10. zsh Tab-Completion for `skein` `[S]`

**Issue:** [#101](https://github.com/kormie/Skein/issues/101)

**Problem:** Eleven subcommands plus per-command flags, none of it completes — every demo involves typing from memory.

**Scope:** `skein completions zsh` subcommand printing a `_skein` function (subcommands + flags + `.skein`/directory positionals); a CLI test pins the completion source to the real command surface so it can't drift; bash/fish are follow-ups.

**Depends on:** Nothing.

---

### 11. Spec Section 8 Sweep `[M]`

**Issue:** [#77](https://github.com/kormie/Skein/issues/77)

**Problem:** Spec examples are largely aligned and covered by `spec_examples_test.exs`, but a few forms remain aspirational (`agent.run_sync()` in testing docs, tuple destructuring, unit type `()`).

**Scope:**
- Re-sweep sections 8.2–8.5: every example either compiles (and is added to `spec_examples_test.exs`) or carries an explicit "Planned" annotation

**Acceptance criteria:**
- Zero unannotated non-compiling examples in the spec
- `spec_examples_test.exs` covers every compiling section-8 example

**Depends on:** Nothing.

---

### 12. Enum Value-Level Exhaustiveness Warning `[S]`

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

### 13. LSP Code Actions from `fix_hint`/`fix_code` `[L]`

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
- Capability checks cover test blocks (#104): test/scenario/golden bodies feed both capability passes — effects inside tests require capabilities (E0012) and count as usage (no W0002 on the `skein new` scaffold; pinned by a scaffold-analyzes-warning-free CLI test)
- Enum variant construction completeness (#96): zero-field variants construct in expression position (`Status.Active`, bare `Active`, `Status.Active()` — all lower to `:active`, matching patterns); unknown variants and wrong constructor arity/types are structured E0010/E0020 with closest-name fix_code (no core_lint crashes remain)
- Types usable from agents (#70): module types are visible to nested agents and the derived JSON Schema flows into `llm.json[T]` requests from agent handlers (verified via recording backend); agents never declare their own `type` blocks — nesting is the route (spec §3.7)
- Agent nesting inside modules (#63): `module Foo { agent Bar }` compiles to `Skein.User.Foo` + `Skein.Agent.Foo.Bar`; module types and capabilities apply to the nested agent; spec §8.4 and `market_research/single_file.skein` ship the nested shape
- Named arguments in calls (#56): `f(name: value)` for local fns and documented effect signatures; positional-then-named mixing, analyzer rewrites to positional order (E0026 for unknown/duplicate/misordered names), spec grammar + section 8 updated
- Release automation (#100, PR #102): green version-bump merges to `main` auto-tag and release (no manual tag step), README badges, per-release docs snapshots incl. `llms*.txt`; superseded PR runs cancel, main/release builds never do
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/ with `llms.txt` endpoints
- CI: format check, `--warnings-as-errors` compile, full test suite
