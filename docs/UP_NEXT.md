# Skein — Up Next (Prioritized Work Items)

**Last updated:** 2026-02-09
**Context:** Phases 1-8 are complete. The core pipeline (lex/parse/analyze/codegen/runtime) works end-to-end. These items close the remaining gaps between `SKEIN_SPEC.md` and the implementation.

---

## How to Use This List

Pick the top incomplete item. Follow the checklist for that item. Mark it done when finished. Each item is self-contained and can be completed in a single session.

**Every item requires:**
- [ ] **TDD** — write tests first, then implement. No exceptions.
- [ ] **Property tests** — use StreamData for pure transforms, PropCheck for stateful components.
- [ ] **Update docs** — keep `docs/SKEIN_SPEC.md`, `docs/ARCHITECTURE.md`, and `docs/IMPLEMENTATION_PLAN.md` accurate.
- [ ] **Update docs site** — update relevant pages under `docs/site/src/content/docs/` and rebuild with `cd docs/site && bunx astro build`.

---

## Priority 1: Standard Library (120+ functions)

**Why first:** Blocks the canonical examples from running. `Uuid.new()`, `Instant.now()`, `List.map()`, `Result.map()` etc. appear throughout spec examples but have no dispatch in the compiler or runtime. This is the single biggest gap.

**Status:** COMPLETE (all 11 modules, 101 functions)

### Scope

Implement all stdlib modules defined in spec sections 5.1-5.11:

| Module | Functions | Spec Section |
|--------|-----------|-------------|
| String | length, slice, contains, split, trim, upcase, downcase, starts_with, ends_with, replace | 5.1 |
| Int | parse, to_string, abs, min, max, clamp | 5.2 |
| Float | parse, to_string, round, ceil, floor | 5.3 |
| List | length, map, filter, reduce, find, first, last, head, tail, take, drop, sort, sort_by, reverse, flatten, concat, contains, any, all, none, zip, uniq, count, group_by | 5.4 |
| Map | get, get!, put, delete, keys, values, entries, size, has, merge, map_values, filter | 5.5 |
| Set | from, add, remove, contains, size, union, intersection, difference, to_list | 5.6 |
| Option | unwrap, map, flat_map, is_some, is_none | 5.7 |
| Result | unwrap, map, map_err, flat_map, is_ok, is_err, ok, err | 5.8 |
| Uuid | new, parse, to_string | 5.9 |
| Instant | now, parse, to_string, add, subtract, diff, is_before, is_after | 5.10 |
| Duration | seconds, minutes, hours, days, to_seconds, to_string | 5.11 |

### Implementation Plan

1. **Analyzer** — Add a stdlib registry mapping `{Module, function_name}` to `{param_types, return_type}`. Type-check calls to stdlib functions during analysis. File: `apps/skein_compiler/lib/skein/analyzer.ex`
2. **Codegen** — Add dispatch in `core_erlang.ex` for `Module.function(args)` calls. Map each stdlib function to an Erlang/Elixir BIF or a Skein runtime helper. File: `apps/skein_compiler/lib/skein/codegen/core_erlang.ex`
3. **Runtime** — Create backing modules where BEAM doesn't have a direct equivalent. Some functions map trivially (e.g., `String.length` -> `:erlang.byte_size` or `String.Chars`), others need thin wrappers. Files: `apps/skein_runtime/lib/skein/runtime/stdlib/`
4. **Higher-order functions** — `List.map`, `List.filter`, etc. take `&fn_name` references. Ensure the codegen correctly handles function references as arguments.

### Suggested Breakdown (Sub-Items)

This is large enough to split across multiple sessions:
- **1a:** String, Int, Float (simple value types, mostly map to Erlang BIFs)
- **1b:** List (largest module, includes higher-order functions)
- **1c:** Map, Set (collection types)
- **1d:** Option, Result (algebraic type operations)
- **1e:** Uuid, Instant, Duration (domain types, need runtime backing modules)

### Testing Checklist

- [ ] Unit tests: every stdlib function has happy-path and error-case tests
- [ ] Property tests (StreamData): round-trip properties (e.g., `String.length(s) >= 0`), identity properties (e.g., `List.reverse(List.reverse(l)) == l`), algebraic laws (e.g., `Set.union(a, b) == Set.union(b, a)`)
- [ ] Integration test: compile a .skein file that uses stdlib functions, load the BEAM, call the functions from Elixir
- [ ] Verify canonical examples (`examples/*.skein`) compile after stdlib is wired up

### Docs Checklist

- [ ] `docs/IMPLEMENTATION_PLAN.md` — add "Phase 9: Standard Library" or mark as part of Phase 8
- [ ] `docs/site/src/content/docs/language/expressions.md` — document stdlib call syntax
- [ ] Consider adding a `docs/site/src/content/docs/reference/stdlib.md` page
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 2: Error Code Alignment

**Why second:** Spec defines 21 error/warning codes. The implementation has 11 codes but some use different numbers than the spec. Aligning these improves agent-writability (agents rely on stable error codes).

**Status:** COMPLETE (all 21 codes aligned + 3 warning codes implemented)

### Spec Error Codes vs Implementation

All 21 error codes and 3 warning codes are now aligned with the spec:

| Code | Spec Meaning | Status |
|------|-------------|--------|
| E0001 | Syntax: Unexpected token | IMPLEMENTED (lexer + parser) |
| E0002 | Syntax: Unterminated string | IMPLEMENTED (lexer) |
| E0003 | Syntax: Invalid number literal | RESERVED (current lexer grammar handles number edge cases) |
| E0010 | Name: Undefined identifier | IMPLEMENTED |
| E0011 | Name: Duplicate definition | IMPLEMENTED (new) |
| E0012 | Capability: Missing capability | IMPLEMENTED (renumbered from E0030) |
| E0013 | Capability: Parameter mismatch | RESERVED |
| E0014 | Tool: Name not declared | IMPLEMENTED (renumbered from E0031) |
| E0015 | Tool: Duplicate short name | IMPLEMENTED (renumbered from E0032) |
| E0020 | Type: Type mismatch | IMPLEMENTED (consolidated: arity, operators, return types) |
| E0021 | Type: Non-exhaustive match | IMPLEMENTED (renumbered from E0024, warning) |
| E0022 | Type: Invalid `!` on non-Result | IMPLEMENTED (new) |
| E0023 | Type: Invalid `?` on non-Result | IMPLEMENTED (new) |
| E0024 | Type: Unknown type name | IMPLEMENTED (renumbered from E0011) |
| E0025 | Type: Wrong constraint annotation | IMPLEMENTED |
| E0030 | Agent: Invalid phase transition | IMPLEMENTED |
| E0031 | Agent: Unreachable phase | IMPLEMENTED (warning) |
| E0032 | Agent: Phase handler missing | IMPLEMENTED |
| E0033 | Agent: transition() outside agent | IMPLEMENTED |
| W0001 | Warning: Unused binding | IMPLEMENTED (new) |
| W0002 | Warning: Unused capability | IMPLEMENTED (new) |
| W0003 | Warning: Unreachable code after stop() | IMPLEMENTED (new) |

### Key Changes Made

1. **Renumbered** — All codes aligned: E0011→E0024 (unknown type), E0012→E0020 (arity→type mismatch), E0021→E0020 (operator→type mismatch), E0024→E0021 (non-exhaustive match), capability E0030→E0012, tool E0031→E0014, tool E0032→E0015.
2. **New error codes** — E0011 (duplicate definition), E0022 (invalid ! on non-Result), E0023 (invalid ? on non-Result).
3. **New warnings** — W0001 (unused binding), W0002 (unused capability), W0003 (unreachable code after stop()).
4. **Warnings no longer block compilation** — `filter_result` returns `{:ok, ast, warnings}` for warnings-only instead of `{:error, warnings}`. LSP shows warnings as diagnostics.

---

## ~~Priority 3: suspend / resume~~ ✅ DONE

**Status:** COMPLETE

Implemented `suspend(reason)` across the full pipeline:

- **AST**: `Skein.AST.Suspend` node with `:reason` and `:meta` fields
- **Parser**: `suspend(expr)` parsed as primary expression
- **Analyzer**: E0034 error for `suspend()` outside agent; W0003 extended for unreachable code after `suspend()`
- **Codegen**: Generates `{:suspend, reason, state, events}` tuple
- **Runtime**: `:suspended` state in gen_statem; `resume/2`, `is_suspended?/1`, `get_suspend_reason/1` APIs
- **Examples**: `refund_agent.skein` (Failed phase) and `incident_triage.skein` (Escalate phase) updated
- **Tests**: Parser (3), analyzer (4), codegen (4), runtime (4), integration (1) — all passing
- **Docs**: Language agents, runtime agents, errors, and overview pages updated

---

## ~~Priority 4: respond.text / respond.html~~ ✅ DONE

**Status:** COMPLETE

Implemented `respond.text(status, body)` and `respond.html(status, body)` across the full pipeline:

- **Codegen**: `respond.text` generates `{:respond_text, status, body}` tuples; `respond.html` generates `{:respond_html, status, body}` tuples
- **Handler**: Dispatch matches all three respond types, returning `{:ok, status, body, content_type}` where content_type is `:json`, `:text`, or `:html`
- **Router**: Sets `Content-Type` headers based on content type: `application/json`, `text/plain`, or `text/html`
- **Examples**: `hello_http.skein` updated with `/health` (text) and `/page` (html) endpoints
- **Tests**: Codegen (3), router (5), property (3) — all passing
- **Docs**: handlers.md updated with "Response Helpers" section

---

## ~~Priority 5: topic.publish / topic.consume~~ ✅ DONE

**Status:** COMPLETE

Implemented `topic.publish` and `topic.consume` (handler topic) across the full pipeline:

- **Parser**: `parse_topic_handler` for `handler topic "name" (param) -> { body }` syntax
- **Analyzer**: `topic.consume` capability required for topic handlers; `topic.publish` capability required for `topic.publish()` effect calls; added to `@effect_namespaces` and `@effect_methods`
- **Codegen**: Topic handlers compile to `__handler_N__/1` functions with `source: :topic` metadata; `topic.publish()` generates `Skein.Runtime.Topic.publish()` calls via `@effect_runtime_modules`
- **Runtime**: `Skein.Runtime.Topic` GenServer with fan-out semantics — all subscribers receive every published message
- **Examples**: `examples/pubsub_notifications.skein` demonstrates HTTP publishing + two topic consumers
- **Tests**: Parser (5), analyzer (7), codegen (6), runtime unit (11), property (7), PropCheck statem (1), integration (6) — all passing
- **Docs**: handlers.md (Topic Handlers section, handler types table), capabilities-and-effects.md (Topics section, capabilities table)

---

## ~~Priority 6: idempotent(key)~~ ✅ DONE

**Status:** COMPLETE

### Scope

- `idempotent(key: String)` — skip handler execution if key was already processed
- Requires persistent storage of processed keys (could use ETS for dev, store for production)

### Implementation Plan

1. **Lexer** — Add `idempotent` as a keyword
2. **AST** — Add `Idempotent` node type
3. **Parser** — Parse `idempotent(expr)` as an expression
4. **Analyzer** — Validate idempotent appears at top of handler body
5. **Codegen** — Generate early-return check against processed-key store
6. **Runtime** — Create `Skein.Runtime.Idempotent` module with ETS-backed key tracking and configurable TTL

### Testing Checklist

- [ ] Unit tests: parse, analyze, generate idempotent calls
- [ ] Runtime tests: first call processes, second call with same key skips
- [ ] Property tests: random keys never produce duplicate processing; TTL expiry allows reprocessing
- [ ] Integration test: queue handler with idempotent guard processes messages exactly once

### Examples Checklist

- [ ] **Amend `examples/queue_worker.skein`** — add `idempotent(msg.id)` at the top of the queue handler body (matching the spec's canonical example in section 8.3). This is the natural home for this feature since idempotent processing is a core queue worker concern.
- [ ] Verify the amended example compiles and its integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/handlers.md` — add an "Idempotent Handlers" section showing the `idempotent(key)` guard at the top of a queue handler, explaining what happens on duplicate keys, and how TTL works
- [ ] `docs/site/src/content/docs/language/capabilities-and-effects.md` — document the idempotent effect
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## ~~Priority 7: trace.annotate(key, value)~~ ✅ DONE

**Status:** COMPLETE

Implemented `trace.annotate(key, value)` across the full pipeline:

- **Analyzer**: Added `"trace"` to `@effect_namespaces` (with `nil` — no capability required) and `["annotate"]` to `@effect_methods`. Modified `check_effect_capability` to handle `nil` (capability-free effects).
- **CodeGen**: Added `"trace" => Skein.Runtime.Trace` to `@effect_runtime_modules`. Generic effect call handler generates `Skein.Runtime.Trace.annotate(key, value, capabilities)`.
- **Runtime**: Added `annotate/2` and `annotate/3` to `Skein.Runtime.Trace`. Records annotations as spans with `kind: :annotation`, `key`, and `value` fields.
- **Examples**: `refund_agent.skein` (Review phase) and `hello_http.skein` (greet handler) updated with `trace.annotate` calls.
- **Tests**: Runtime (6 unit + 3 property), analyzer (5), codegen (6), examples (40) — all passing.
- **Docs**: capabilities-and-effects.md updated with Trace section and annotation fields in tracing table.

---

## ~~Priority 8: llm.embed~~ ✅ DONE

**Status:** COMPLETE

Implemented `llm.embed(model, input)` across the full pipeline:

- **Analyzer**: Added `"embed"` to `@effect_methods["llm"]` — uses same `model` capability as chat/json/stream
- **Codegen**: Added `generate_expr` clause for `llm.embed` — generates `Skein.Runtime.Llm.embed(model, input, capabilities)` calls
- **Runtime**: Added `embed/3` to `Skein.Runtime.Llm` with pluggable backend support; `embed/2` callback in Backend behaviour; TestBackend returns deterministic 8-dimensional vectors via hash-based generation; FailingBackend returns provider errors
- **Examples**: `examples/semantic_search.skein` demonstrates RAG-style embed→retrieve→chat pipeline with memory and HTTP handlers
- **Tests**: Runtime unit (7), property (5), integration (3), examples (4) — all passing
- **Docs**: capabilities-and-effects.md updated with `llm.embed` in LLM section, return values, and tracing table

---

## ~~Priority 9: Remaining Capability Kinds (process.spawn, timer, event.log)~~ ✅ DONE

**Status:** COMPLETE

Implemented all three remaining capability kinds across the full pipeline:

- **Analyzer**: Added `process` → `process.spawn`, `timer` → `timer`, `event` → `event.log` to `@effect_namespaces` and corresponding methods to `@effect_methods`
- **Codegen**: Added `process` → `Skein.Runtime.Process`, `timer` → `Skein.Runtime.Timer`, `event` → `Skein.Runtime.EventLog` to `@effect_runtime_modules`
- **Runtime**: Created three new modules:
  - `Skein.Runtime.Process` — DynamicSupervisor-based task spawning with trace integration
  - `Skein.Runtime.Timer` — GenServer-managed one-shot (`after`) and recurring (`interval`) timers with cancellation
  - `Skein.Runtime.EventLog` — ETS-backed structured event logging with query support
- **Examples**: `examples/background_tasks.skein` (process.spawn + timer) and `examples/audit_log.skein` (event.log)
- **Tests**: Runtime unit (31), property (12), analyzer (13), codegen (8), examples (8) — all passing
- **Docs**: capabilities-and-effects.md updated with Process Spawning, Timer Effects, and Event Logging sections

### Scope

- `capability process.spawn(...)` — spawn supervised processes
- `capability timer(...)` — timer-based scheduling within a module
- `capability event.log(...)` — structured event logging

### Implementation Plan

For each capability kind:
1. **Analyzer** — Add to capability checking in `@effect_namespaces`
2. **Codegen** — Generate appropriate effect calls
3. **Runtime** — Create backing modules: `Skein.Runtime.Process`, `Skein.Runtime.Timer`, `Skein.Runtime.EventLog`

### Testing Checklist

- [ ] Unit tests per capability: analyzer accepts/rejects, codegen produces correct calls
- [ ] Runtime tests: each capability's operations work correctly
- [ ] Property tests: capability checking holds for random programs; timer scheduling is monotonic

### Examples Checklist

- [ ] **Create `examples/background_tasks.skein`** — a new example demonstrating `process.spawn` and `timer` together: a module that spawns background worker processes on demand (e.g., for image processing) and uses timers for timeout/retry logic. Show `capability process.spawn(...)`, `capability timer(...)`, spawning a process, and setting a timer callback.
- [ ] **Create `examples/audit_log.skein`** — a new example demonstrating `event.log`: an HTTP service that logs structured events for every request (e.g., `event.log("user.login", { user_id: id, ip: req.headers.x_forwarded_for })`). Show `capability event.log(...)` and multiple log calls at different points in a handler.
- [ ] Verify all new examples compile and their integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/capabilities-and-effects.md` — add sections for `process.spawn`, `timer`, and `event.log` capabilities with code examples for each
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Completed Items

_Move items here as they are finished, with date and session link._

- [x] **Standard Library 1a: String, Int, Float** — 2026-02-09 — session_01Dv2MiJcMip17YGdajaMDs5
- [x] **Standard Library 1b: List** (24 functions, FnRef fix for higher-order) — 2026-02-09 — session_01Dv2MiJcMip17YGdajaMDs5
- [x] **Standard Library 1c: Map, Set** — 2026-02-09 — session_01Dv2MiJcMip17YGdajaMDs5
- [x] **Standard Library 1d: Option, Result** — 2026-02-09 — session_01Dv2MiJcMip17YGdajaMDs5
- [x] **Standard Library 1e: Uuid, Instant, Duration** — 2026-02-09 — session_01Dv2MiJcMip17YGdajaMDs5
- [x] **Error Code Alignment** (21 error codes + 3 warning codes) — 2026-02-09 — session_013qLiHBBTW4ei2v7D5Vy6QA
- [x] **suspend / resume** — (complete, see Priority 3 section)
- [x] **respond.text / respond.html** (codegen + handler + router + docs) — 2026-02-09 — session_01CmpRm5pVDPuerofBgz7CHJ
- [x] **topic.publish / topic.consume** (parser + analyzer + codegen + runtime + docs) — 2026-02-09 — session_01HGdUnDFnp5AYRcZD7t1v5m
- [x] **idempotent(key)** (lexer + parser + analyzer + codegen + runtime + docs) — 2026-02-09 — session_01LuWtXuwSy6E193S4X23JDK
- [x] **trace.annotate(key, value)** (analyzer + codegen + runtime + docs) — 2026-02-11 — session_019MuBUA8XW6AhCYs6B8iogz
- [x] **llm.embed** (analyzer + codegen + runtime + example + docs) — 2026-02-11 — session_01HUDduKnWfVoeXi4vrFYXXM
- [x] **Remaining Capabilities: process.spawn, timer, event.log** (analyzer + codegen + runtime + examples + docs) — 2026-02-11 — session_01UAWv6aC96MieHScoFY6qL8
- [x] **Unified Event Store** (EventStore + Trace facade + EventLog folded in + Memory event-sourced + Replay enhanced + docs) — 2026-02-11 — session_01QqF2LkNnAztvHdkA2rRdkh
