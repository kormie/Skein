# Skein Roadmap

**As of:** 2026-06-10
**Based on:** `docs/AUDIT_FIRST_PRINCIPLES.md`, the 2026-06-09 codebase audit (`docs/AUDIT_2026-06-09.md`), and a source-verified status pass on 2026-06-10.

This is the forward-looking work list for Skein. Items are ordered by impact — the top items close the biggest gaps between the language's stated goals and its current reality.

Every item is self-contained. Pick the top incomplete one and work it.

**Every item requires:**
- TDD — tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

**Sizing key:** S = a few hours, M = half a day, L = a full day, XL = multiple days

---

## Current State

The compilation pipeline works end-to-end: lexer, parser, analyzer, codegen, and runtime are functional. **1,413 tests + 189 property tests pass.** Fourteen example programs (thirteen single-file + one multi-file) compile and run, all covered by integration tests. The LSP, CLI, docs site, and binary distribution (Burrito) are operational.

Most of the foundational gap-closing work from earlier roadmap revisions is **done**: real type inference for field access and pattern bindings, schema derivation for nested types and enum variants, the production Anthropic LLM backend, runtime capability enforcement for tool/LLM/topic (name- and model-aware), agent instance-scoped memory, error `context` + `fix_code` on all compiler errors, float-aware division, multi-`emit` accumulation, tool input validation, contextual (non-reserved) keywords, the persistent SQLite EventStore backend, string-literal match patterns, `store.<table>.get!/put!`, and the `queue.consume`/`schedule.trigger` capability naming.

The remaining gaps are listed below.

---

## Tier 1: Language Surface

### 1. Named Arguments in Calls `[L]`

**Problem:** The spec grammar (section 3.2) allows named arguments (`named_arg = lower_ident ":" expr`), and the first-principles document shows calls like `llm.json[T](model: "...", system: PROMPT)`. The parser only supports positional arguments — `parse_args` has no named-argument production. All shipped examples and docs use the positional form.

**Scope:**
- Parser: accept `name: expr` entries in `parse_args`; represent as a `%AST.NamedArg{name, value}` (or a keyword-map argument node)
- Analyzer: match named args against parameter names; produce a structured error for unknown/duplicate names
- Codegen: reorder named args into positional order at the call site
- Update spec section 8 examples to use named args where they improve readability

**Acceptance criteria:**
- `llm.chat(model: "claude-opus-4-8", system: "...", input: ticket)` compiles and runs
- Mixing positional-then-named works; named-then-positional is a structured error
- Unknown argument name produces an error with `fix_hint` listing valid names
- All existing positional call sites still compile

**Depends on:** Nothing.

---

### 2. Agent Nesting Inside Modules `[M]`

**Problem:** The spec (section 8.4) shows `agent RefundAgent { ... }` nested inside `module RefundService { ... }`, but `parse_declaration` doesn't accept `agent` as a module-level declaration. The `examples/market_research/` project works around this with one file per construct.

**Scope:**
- Add an `agent` clause to `parse_declaration`, routing to the existing `parse_agent`
- Codegen: namespace nested agents (`module Foo { agent Bar }` → `Skein.Agent.Foo.Bar`)
- Types and capabilities declared at module level should be visible to the nested agent

**Acceptance criteria:**
- `module RefundService { agent RefundAgent { ... } }` parses, analyzes, and compiles
- Module-level `type` declarations are usable in the nested agent (e.g. `llm.json[RefundDecision]`)
- The `market_research` example can be restructured into a single file (keep the two-file version too — both shapes should work)

**Depends on:** Nothing.

---

### 3. Types Usable from Agents `[M]`

**Problem:** Agents cannot declare `type` blocks, and (until item 2 lands) cannot live inside modules that do. As a result `llm.json[SomeType]` is unusable from agent bodies — the canonical "schema-constrained LLM decision" pattern only works in module functions today.

**Scope:**
- Either allow `type` declarations in agent bodies, or resolve type references in agents against sibling/parent module declarations once item 2 lands
- Schema generation for those types must flow into `llm.json` calls in phase handlers

**Acceptance criteria:**
- An agent phase handler can call `llm.json[RefundDecision](...)` with `RefundDecision` declared in the same compilation unit
- The generated JSON Schema appears in the LLM request (verifiable through a test backend)

**Depends on:** Item 2 (the module-nesting route is the spec-aligned one).

---

## Tier 2: Runtime Completeness

### 4. Schedule Handler Auto-Firing `[M]`

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

### 5. Agent `emit` Events to EventStore `[M]`

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

### 6. Replay Backend Injection `[L]`

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

### 7. Stream/Pool-Scoped Runtime Capability Checks `[M]` *(needs surface design first)*

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

### 8. `process.spawn` Task Bodies `[M]`

**Problem:** `process.spawn("name")` spawns a supervised no-op task carrying the name in its trace span. There is no way to attach actual work to the spawned process from Skein source.

**Scope:**
- Design the surface (likely `process.spawn("name", &some_fn)` with a function reference)
- Wire codegen to pass the function through to `Skein.Runtime.Process.spawn/2`, which already executes zero-arity functions under the DynamicSupervisor

**Acceptance criteria:**
- A spawned task executes a named module function in the background
- Crashes in the task don't take down the caller (already guaranteed by the supervisor; add a test from Skein source)

**Depends on:** A spec decision on the call surface.

---

## Tier 3: Polish

### 9. Enum Value-Level Exhaustiveness Warning `[S]`

**Problem:** Exhaustiveness checking is variant-level only. `match e { Event.Charge(5) -> ... }` satisfies "Charge is covered", but `Event.Charge(10)` raises `case_clause` at runtime. (Plain literal matches without a catch-all now compile to an explicit `case_clause` raise — the gap is the missing *warning*.)

**Scope:**
- Analyzer: warn (new W code) when a variant arm uses literal field patterns and no wildcard arm exists
- See `check_exhaustiveness/4` in `analyzer.ex`

**Acceptance criteria:**
- `match e { Event.Charge(5) -> "five" }` produces a warning suggesting a wildcard arm
- Adding `_ ->` or a variable binding silences it

**Depends on:** Nothing.

---

### 10. Spec Section 8 Sweep `[M]`

**Problem:** Spec examples are largely aligned and covered by `spec_examples_test.exs`, but a few forms remain aspirational (named args — item 1, nested agents — item 2, `agent.run_sync()` in testing docs, tuple destructuring, unit type `()`).

**Scope:**
- After items 1–2 land, re-sweep sections 8.2–8.5: every example either compiles (and is added to `spec_examples_test.exs`) or carries an explicit "Planned" annotation

**Acceptance criteria:**
- Zero unannotated non-compiling examples in the spec
- `spec_examples_test.exs` covers every compiling section-8 example

**Depends on:** Items 1 and 2.

---

## Post-MVP Backlog

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
- Type inference: field access through user-defined types, pattern bindings carry `Result`/variant inner types
- Schema derivation: nested user types, enum `oneOf`, `Map[K, V]` `additionalProperties`, circular-reference safety
- Production LLM backend: Anthropic Messages API (chat, json, stream) with retry and structured errors; current model IDs throughout
- Runtime capability enforcement: store, memory, HTTP, topic (name-scoped), tool (tool-name-scoped), LLM (model-scoped), presence checks for process/timer/event.log
- Agent instance-scoped memory (`{agent}:{instance}:{key}`)
- Error system: 21 error + 3 warning codes aligned with the spec; `context` and `fix_code` populated everywhere
- Codegen correctness: float-aware division, multi-`emit` accumulation, string-literal match patterns, explicit non-exhaustive-match failure clauses, `state.field` in nested positions, `method!(args)`/`method?(args)` parsing, `store.get!/put!`
- Tool input validation against generated JSON Schema (`validation_error`)
- Contextual keywords un-reserved (12 tokens usable as identifiers outside their construct)
- `queue.consume` / `schedule.trigger` capability naming (old names get a targeted rename hint)
- Standard library: 11 modules, 101 functions
- suspend/resume, respond.text/html, topic pub/sub, idempotent(key), trace.annotate, llm.embed, process.spawn, timer, event.log
- LSP: completions, hover, diagnostics, semantic tokens, document symbols, go-to-definition (+ request/response integration tests)
- CLI: new, build (`--output`), test, run, trace; structured errors for malformed flags
- Distribution: Burrito binaries (Linux x86_64/ARM64, macOS x86_64/ARM64), GitHub Release automation on `v*` tags
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/ with `llms.txt` endpoints
- CI: format check, `--warnings-as-errors` compile, full test suite
