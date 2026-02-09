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

**Status:** NOT IMPLEMENTED

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

**Status:** PARTIALLY IMPLEMENTED (11 of 21, some misaligned)

### Spec Error Codes vs Implementation

| Code | Spec Meaning | Implementation Status |
|------|-------------|----------------------|
| E0001 | Syntax: Unexpected token | MISSING — parser returns ad-hoc errors |
| E0002 | Syntax: Unterminated string | MISSING — lexer returns ad-hoc errors |
| E0003 | Syntax: Invalid number literal | MISSING — lexer returns ad-hoc errors |
| E0010 | Name: Undefined identifier | IMPLEMENTED (may use different code) |
| E0011 | Name: Duplicate definition | IMPLEMENTED (may be used for "unknown type" instead) |
| E0012 | Capability: Missing capability | NEEDS AUDIT — impl uses this for wrong arity |
| E0013 | Capability: Parameter mismatch | MISSING |
| E0014 | Tool: Name not declared | MISSING (impl uses E0031) |
| E0015 | Tool: Duplicate short name | MISSING (impl uses E0032) |
| E0020 | Type: Type mismatch | IMPLEMENTED |
| E0021 | Type: Non-exhaustive match | NEEDS AUDIT — impl uses this for operator type error |
| E0022 | Type: Invalid `!` on non-Result | MISSING |
| E0023 | Type: Invalid `?` on non-Result | MISSING |
| E0024 | Type: Unknown type name | NEEDS AUDIT — impl uses this for non-exhaustive match |
| E0025 | Type: Wrong constraint annotation | IMPLEMENTED |
| E0030 | Agent: Invalid phase transition | NEEDS AUDIT — impl uses this for missing capability |
| E0031 | Agent: Unreachable phase | NEEDS AUDIT — impl uses this for tool name |
| E0032 | Agent: Phase handler missing | NEEDS AUDIT — impl uses this for dup tool name |
| E0033 | Agent: transition() outside agent | IMPLEMENTED |
| W0001 | Warning: Unused binding | MISSING |
| W0002 | Warning: Unused capability | MISSING |
| W0003 | Warning: Unreachable code after stop() | MISSING |

### Implementation Plan

1. **Audit** — Read the analyzer and map every current error emission to its code. Document the actual vs. spec mapping.
2. **Renumber** — Align implementation codes with the spec. This is a breaking change to error output, so do it all at once.
3. **Add syntax errors** (E0001-E0003) — Wrap lexer and parser errors in `Skein.Error` structs with proper codes.
4. **Add missing type errors** (E0022, E0023) — `!` and `?` operator validation.
5. **Add warnings** (W0001-W0003) — Unused binding detection, unused capability detection, unreachable code after stop().

### Testing Checklist

- [ ] Unit tests: each error code has a test with a .skein snippet that triggers it
- [ ] Property tests: generate random invalid programs and verify errors always have valid codes
- [ ] Snapshot tests: expected error JSON output for each code
- [ ] Verify `fix_hint` and `fix_code` fields are populated for every error

### Docs Checklist

- [ ] `docs/site/src/content/docs/compiler/errors.md` — update with complete error code table matching the spec
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 3: suspend / resume

**Why third:** Used in the canonical refund agent example (spec section 8.4, line 759: `suspend(reason: "Requires human review")`). Tokens already exist in the lexer but nothing else is implemented.

**Status:** TOKENS ONLY (keywords recognized, no parser/AST/codegen/runtime)

### Scope

- `suspend(reason: String)` — pause agent execution, persist state, await external input
- `resume(input: Map)` — resume a suspended agent with new input

### Implementation Plan

1. **AST** — Add `Suspend` and `Resume` node types to `Skein.AST` (like `Transition` and `Stop`)
2. **Parser** — Parse `suspend(expr)` and `resume(expr)` as expressions inside agent handlers
3. **Analyzer** — Validate suspend/resume only appear inside agent context (like transition/stop). Add error code for suspend/resume outside agent.
4. **Codegen** — Generate gen_statem `{:next_state, :suspended, ...}` for suspend; resume triggers re-entry
5. **Runtime** — Extend `Skein.Runtime.Agent` to support a `:suspended` state with `resume/2` API
6. **Agent state** — Add `suspended` field to agent queryable state (`agent.suspended == true` must work in tests)

### Testing Checklist

- [ ] Unit tests: parse suspend/resume expressions, generate correct AST
- [ ] Analyzer tests: suspend outside agent produces error, suspend inside agent passes
- [ ] Codegen tests: compiled agent enters suspended state
- [ ] Runtime tests: agent suspends, state is queryable, resume with input continues execution
- [ ] Property tests (PropCheck): agent state machine model includes suspend/resume transitions
- [ ] Integration test: the canonical refund agent example compiles and the Failed phase suspends

### Examples Checklist

- [ ] **Amend `examples/refund_agent.skein`** — add `suspend(reason: "Requires human review")` in the Failed phase handler (matching the spec's canonical example in section 8.4)
- [ ] **Amend `examples/incident_triage.skein`** — add a suspended-for-escalation path where high-severity incidents suspend for human review
- [ ] Verify all amended examples compile and their integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/runtime/agents.md` — add a "Suspend and Resume" section with a full code example showing an agent that suspends in a phase, the external resume call, and continuation
- [ ] `docs/site/src/content/docs/language/agents.md` — add suspend/resume to the syntax reference with inline examples
- [ ] `docs/site/src/content/docs/reference/agent-quick-reference.md` — add suspend/resume to the quick reference table
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 4: respond.text / respond.html

**Why fourth:** Small gap, easy win. Only `respond.json` is implemented; spec examples imply text and html should work.

**Status:** NOT IMPLEMENTED (respond.json works)

### Implementation Plan

1. **Codegen** — Add `respond.text(status, body)` and `respond.html(status, body)` handlers in `core_erlang.ex` alongside existing `respond.json`
2. **Runtime** — Extend handler dispatch in `Skein.Runtime.Handler` to recognize `{:respond_text, status, body}` and `{:respond_html, status, body}` tuples
3. **Router** — Set appropriate Content-Type headers (`text/plain`, `text/html`) in the Plug response

### Testing Checklist

- [ ] Unit tests: codegen produces correct tuples for respond.text and respond.html
- [ ] Integration tests: HTTP handler returns text/plain and text/html responses with correct headers
- [ ] Property tests: arbitrary status codes and body strings produce valid responses

### Examples Checklist

- [ ] **Amend `examples/hello_http.skein`** — add a `handler http GET "/health" (req) -> { respond.text(200, "ok") }` endpoint and a `handler http GET "/page" (req) -> { respond.html(200, "<h1>Hello</h1>") }` endpoint to showcase all three respond variants side-by-side
- [ ] Verify the amended example compiles and its integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/handlers.md` — add a "Response Helpers" section showing all three variants (`respond.json`, `respond.text`, `respond.html`) with code examples, expected Content-Type headers, and when to use each
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 5: topic.publish / topic.consume

**Why fifth:** Defined in spec section 6.6. Needed for pub/sub patterns. The queue runtime already exists and can serve as a template.

**Status:** NOT IMPLEMENTED

### Scope

- `capability topic.publish("name")` / `capability topic.consume("name")`
- `topic.publish(name: String, data: T) -> Result[String, PublishError]`
- `handler topic "name" (msg) -> { ... }` syntax

### Implementation Plan

1. **Parser** — Add `"topic"` to handler source options (currently only http/queue/schedule)
2. **Analyzer** — Add `"topic"` to `@effect_namespaces` with method `["publish"]`
3. **Codegen** — Generate topic.publish calls and topic handler wrappers
4. **Runtime** — Create `Skein.Runtime.Topic` module (fan-out semantics vs queue's single-consumer). Model after `Skein.Runtime.Queue` but with broadcast delivery to all subscribers.

### Testing Checklist

- [ ] Unit tests: parse topic handlers, analyze topic capabilities, generate topic codegen
- [ ] Runtime tests: publish a message, multiple consumers receive it (fan-out behavior)
- [ ] Property tests (StreamData): random topic names and payloads
- [ ] Property tests (PropCheck): stateful model of topic pub/sub — verify delivery ordering and no message loss
- [ ] Integration test: .skein file with topic handler compiles and dispatches messages

### Examples Checklist

- [ ] **Create `examples/pubsub_notifications.skein`** — a new example demonstrating the topic pattern: one module publishes order events to a topic, two handler modules consume from the same topic (e.g., one sends email notifications, one updates analytics). Show `capability topic.publish("order.events")`, `capability topic.consume("order.events")`, `topic.publish(...)` calls, and `handler topic "order.events" (msg) -> { ... }` handlers.
- [ ] **Amend `examples/queue_worker.skein`** — if appropriate, add a topic.publish call alongside the existing queue handler to show the difference between queue (single consumer) and topic (fan-out) semantics
- [ ] Verify all new/amended examples compile and their integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/capabilities-and-effects.md` — add a "Topics" section (alongside the existing queue/schedule sections) with code examples showing publish and consume patterns, and a note contrasting topic fan-out vs queue single-consumer
- [ ] `docs/site/src/content/docs/language/handlers.md` — add `handler topic` to the handler types table and add a "Topic Handlers" section with a full code example
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 6: idempotent(key)

**Why sixth:** Defined in spec section 6.9. Used in the canonical queue worker example (spec section 8.3, line 628). Important for reliable message processing.

**Status:** NOT IMPLEMENTED

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

## Priority 7: trace.annotate(key, value)

**Why seventh:** Defined in spec section 6.10. Enhances observability. Small scope.

**Status:** NOT IMPLEMENTED

### Implementation Plan

1. **Analyzer** — Add `"trace"` to `@effect_namespaces` with method `["annotate"]`
2. **Codegen** — Generate `Skein.Runtime.Trace.annotate(key, value)` calls
3. **Runtime** — Add `annotate/2` function to `Skein.Runtime.Trace` that attaches key-value metadata to the current span

### Testing Checklist

- [ ] Unit tests: codegen produces correct trace.annotate calls
- [ ] Runtime tests: annotations appear in span metadata when queried
- [ ] Property tests: arbitrary key/value strings produce valid annotations; special characters don't break storage

### Examples Checklist

- [ ] **Amend `examples/refund_agent.skein`** — add `trace.annotate("ticket_id", state.ticket_id)` and `trace.annotate("decision", d.action)` calls inside the Analyze phase handler, showing how to enrich trace spans with business context
- [ ] **Amend `examples/hello_http.skein`** — add `trace.annotate("user", name)` inside an HTTP handler to show the simplest possible tracing example
- [ ] Verify all amended examples compile and their integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/capabilities-and-effects.md` — add a "Trace" section showing `trace.annotate(key, value)` with a code example of annotating an HTTP handler span and an agent phase span, and explain that annotations appear in the `/__skein/traces` debug endpoint
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 8: llm.embed

**Why eighth:** Defined in spec section 6.4. Needed for RAG patterns. Extends existing LLM runtime.

**Status:** NOT IMPLEMENTED

### Scope

`llm.embed(model: String, input: String) -> Result[List[Float], LlmError]`

### Implementation Plan

1. **Analyzer** — Add `"embed"` to `@effect_methods["llm"]`
2. **Codegen** — Generate `Skein.Runtime.Llm.embed(...)` calls
3. **Runtime** — Add `embed/3` function to `Skein.Runtime.Llm` with pluggable backend support (test backend returns deterministic vectors)

### Testing Checklist

- [ ] Unit tests: codegen produces correct llm.embed calls
- [ ] Runtime tests: embed returns float list via test backend
- [ ] Property tests: arbitrary input strings produce valid float-list embeddings; vector dimensionality is consistent per model

### Examples Checklist

- [ ] **Create `examples/semantic_search.skein`** — a new example demonstrating RAG-style semantic search: an agent that takes a user query, calls `llm.embed(model, query)` to get a vector, stores/retrieves embeddings from memory, and uses `llm.chat` to generate an answer grounded in retrieved context. Show the full `capability model(...)` + `capability memory.kv(...)` setup and the embed→retrieve→chat pipeline.
- [ ] Verify the new example compiles and its integration tests pass

### Docs Checklist

- [ ] `docs/site/src/content/docs/language/capabilities-and-effects.md` — add `llm.embed` to the LLM section alongside chat/json/stream, with a code example showing embedding text and a note about expected return shape
- [ ] Rebuild docs site: `cd docs/site && bunx astro build`

---

## Priority 9: Remaining Capability Kinds (process.spawn, timer, event.log)

**Why ninth:** Defined in spec section 3.2. Lower priority because no canonical examples use them yet.

**Status:** NOT IMPLEMENTED (parser accepts the syntax but no analyzer/codegen/runtime backing)

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

<!-- Example:
- [x] **Standard Library: String, Int, Float** — 2026-02-15 — session_abc123
-->
