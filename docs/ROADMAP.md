# Skein Roadmap

**As of:** 2026-02-11
**Based on:** `docs/AUDIT_FIRST_PRINCIPLES.md`

This is the forward-looking work list for Skein. Items are ordered by impact -- the top items close the biggest gaps between the language's stated goals and its current reality.

Every item is self-contained. Pick the top incomplete one and work it.

**Every item requires:**
- TDD -- tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

---

## Current State

The compilation pipeline works end-to-end. Lexer, parser, analyzer, codegen, and runtime are functional. 1,176 tests + 182 property tests pass. 11 example `.skein` files compile and run. The LSP, CLI, and docs site are operational.

The biggest gaps are in the type system (most expressions infer to `:unknown`), spec-example alignment (canonical examples use unimplemented syntax), and runtime capability enforcement (4 of 9 subsystems don't check capabilities at all).

---

## Tier 1: Critical (Undermines Core Promises)

### 1. Real Type Inference for Field Access and Pattern Bindings

**Problem:** `infer_type(%AST.FieldAccess{}, _env)` returns `{:unknown, []}`. Pattern variables bind as `:unknown`. This means `user.email + 42` compiles without error. The "Types Are Contracts" principle (P3) is not delivered.

**Scope:**
- Track user-defined type declarations in the analyzer environment as `%{type_name => %{field_name => type}}`
- `infer_type(%AST.FieldAccess{})`: look up the subject's type, then look up the field in that type's field map
- `bind_pattern`: when matching `Ok(value)`, bind `value` to the inner type of the `Result`; when matching `Variant(field)`, bind to the variant's field type
- `infer_type(%AST.Call{})` for user-type constructors: return the named type

**Files:**
- `apps/skein_compiler/lib/skein/analyzer.ex` -- `infer_type/2`, `bind_pattern/2`, environment tracking
- `apps/skein_compiler/test/skein/analyzer_test.exs` -- new tests for field access type checking
- `apps/skein_compiler/test/skein/analyzer_property_test.exs` -- property: field access on typed records resolves correctly

**Acceptance criteria:**
- `user.email` where `user: User` and `User` has `email: String` infers to `:string`
- `user.email + 42` produces E0020 (type mismatch)
- `match result { Ok(val) -> val.name }` infers `val` from the `Result[T, E]` type parameter
- All existing tests still pass

---

### 2. Schema Derivation for Nested Types and Enum Variants

**Problem:** `type Order { customer: Customer }` generates `{"type": "object"}` for the `customer` field instead of inlining `Customer`'s schema. Data-carrying enum variants lose their field information. `Map[K, V]` loses type parameters.

**Scope:**
- `SchemaGen.type_to_schema/1`: resolve `{:user_type, name}` by looking up the type declaration and recursively generating its schema
- Enum variants with fields: generate `oneOf` with each variant as an object schema
- `Map[K, V]`: generate `additionalProperties` from the value type
- `List[T]`: generate `items` from the element type (already works for built-in T, extend to user types)

**Files:**
- `apps/skein_compiler/lib/skein/codegen/schema_gen.ex`
- `apps/skein_compiler/test/skein/codegen/schema_gen_test.exs`

**Acceptance criteria:**
- Nested user type generates fully resolved JSON Schema
- `enum Event { Charge(amount: Int) }` generates `oneOf` with variant schemas
- `Map[String, Int]` generates `{"type": "object", "additionalProperties": {"type": "integer"}}`
- Tool manifests with nested types produce complete, valid schemas

---

### 3. Align Spec Examples with Implementation

**Problem:** The canonical examples in `SKEIN_SPEC.md` sections 8.2-8.5 use syntax that doesn't exist: object literals (`{ "error": "not found" }`), named arguments (`model: "..."`), tuple destructuring, unit type `()`, anonymous functions in stubs, and `agent.run_sync()`. An LLM given the spec will generate code that doesn't compile.

**Two paths (pick one):**

**Path A: Implement the missing syntax** (larger, but fulfills the vision)
- Add map literal parsing: `{ key: value, ... }` and `{ "key": value, ... }`
- Add named argument parsing: `fn(name: value, ...)`
- Add tuple destructuring: `let (a, b) = expr`
- Add unit type: `()`

**Path B: Rewrite spec examples** (smaller, pragmatic)
- Rewrite sections 8.2-8.5 to use only implemented syntax
- Replace `{ "error": "not found" }` with string responses
- Replace named args with positional args
- Replace `agent.run_sync()` with the actual test pattern
- Add a "Spec Examples Alignment" note explaining current limitations

**Recommendation:** Path A for map literals and named arguments (these are fundamental). Path B for `agent.run_sync()` and stub syntax (test infrastructure can evolve separately).

**Acceptance criteria:**
- Every example in `SKEIN_SPEC.md` section 8 compiles successfully
- Or: every example is clearly marked with what's implemented vs. planned

---

### 4. Runtime Capability Enforcement

**Problem:** 4 of 9 runtime effect subsystems ignore capabilities entirely. Tool and LLM checks are presence-only (any `tool.use` or `model` capability passes, regardless of the specific tool/model named).

**Scope:**

| Subsystem | Current | Target |
|-----------|---------|--------|
| Tool | Any `tool.use` passes | Check specific tool name against declared `tool.use(ToolName)` list |
| LLM | Any `model` passes | Check provider and model string against declared `model(provider, model)` |
| Topic | `_capabilities` ignored | Check topic name against declared `topic.publish(name)` or `topic.consume(name)` |
| Process | `_capabilities` ignored | Check agent name and max against declared `process.spawn(agent, max)` |
| Timer | `_capabilities` ignored | Check presence of `timer` capability |
| EventStore | `_capabilities` ignored | Check stream name against declared `event.log(stream)` |

**Files:**
- `apps/skein_runtime/lib/skein/runtime/tool.ex`
- `apps/skein_runtime/lib/skein/runtime/llm.ex`
- `apps/skein_runtime/lib/skein/runtime/topic.ex`
- `apps/skein_runtime/lib/skein/runtime/process.ex`
- `apps/skein_runtime/lib/skein/runtime/timer.ex`
- `apps/skein_runtime/lib/skein/runtime/event_store.ex`
- Corresponding test files

**Acceptance criteria:**
- `tool.call(Stripe.Refund, ...)` with `capability tool.use(Slack.PostMessage)` raises `CapabilityViolation`
- `llm.chat("openai", "gpt-4", ...)` with `capability model("anthropic", "claude-sonnet-4-5")` raises `CapabilityViolation`
- `topic.publish("orders", ...)` with `capability topic.publish("billing")` raises `CapabilityViolation`
- All existing tests still pass

---

## Tier 2: Serious (Significant Functionality Gaps)

### 5. Fix Agent Stateful Test (`agent_statem_test.exs`)

**Problem:** The PropCheck stateful test for agent lifecycle fails to compile because it calls `Skein.Compiler.compile_string/1` from `skein_runtime`, which doesn't depend on `skein_compiler`.

**Fix:** Either add `skein_compiler` as a test-only dependency of `skein_runtime`, or move the test to `skein_compiler`'s test suite (where the compiler is available).

**Files:**
- `apps/skein_runtime/test/skein/runtime/agent_statem_test.exs`
- Possibly `apps/skein_runtime/mix.exs` (add test dep)

---

### 6. Agent Instance-Scoped Memory

**Problem:** The first principles (Section 6.3) promise memory is "implicitly scoped to the agent instance" with keys stored as `RefundAgent:<instance_id>:decision`. In reality, memory uses the declared namespace without instance scoping. Two concurrent agent instances sharing a `memory.kv` namespace will overwrite each other.

**Scope:**
- In `Skein.Runtime.Agent`, inject a unique instance ID into the agent's state at init
- When an agent process calls `memory.put/get/delete`, prepend `{agent_name}:{instance_id}:` to the key
- This scoping should be transparent -- the agent code writes `memory.put("decision", d)` and gets automatic scoping

**Files:**
- `apps/skein_runtime/lib/skein/runtime/agent.ex`
- `apps/skein_runtime/lib/skein/runtime/memory.ex`
- `apps/skein_runtime/test/skein/runtime/agent_test.exs` (new)

---

### 7. Replay Engine -- Actual Replay

**Problem:** `Skein.Runtime.Replay` reads traces and reconstructs memory, but cannot inject recorded responses into a live execution. The three modes (recorded/live/hybrid) described in the first principles are not functional.

**Scope:**
- Implement recorded-mode replay: override LLM, HTTP, and tool backends with recorded responses during replay
- Use process dictionary or a GenServer to hold the replay state
- Match replay events by kind + sequence position
- Return recorded results instead of executing real effects

**Files:**
- `apps/skein_runtime/lib/skein/runtime/replay.ex`
- `apps/skein_runtime/test/skein/runtime/replay_test.exs`

---

### 8. Production LLM Backend

**Problem:** The LLM client has 7 test backends but zero HTTP backends. No real LLM provider can be called.

**Scope:**
- Implement `Skein.Runtime.Llm.AnthropicBackend` (or `HttpBackend` with provider config)
- HTTP client via `:httpc` or `Req` (if available)
- Handle API key from `Secret.get("ANTHROPIC_API_KEY")`
- Support `chat`, `json` (with schema in system prompt), `stream`, and `embed`
- Retry on rate limits with `retry_after` from response headers

**Files:**
- `apps/skein_runtime/lib/skein/runtime/llm/anthropic_backend.ex` (new)
- `apps/skein_runtime/test/skein/runtime/llm/anthropic_backend_test.exs` (new, with recorded responses)

---

### 9. Populate Error `context` and Expand `fix_code`

**Problem:** The `context` field on `Skein.Error` is always `nil`. `fix_code` is only present on 5 of 24 error codes. This weakens the LLM self-correction loop.

**Scope:**
- Pass source text (or relevant excerpt) through the analyzer so errors can include `context`
- Add `fix_code` to at least: E0020 (type mismatch), E0010 (undefined identifier), E0030 (invalid transition), E0022/E0023 (invalid !/?)
- `context` should be the source expression that triggered the error

**Files:**
- `apps/skein_compiler/lib/skein/analyzer.ex`
- `apps/skein_compiler/lib/skein/error.ex`

---

### 10. Fix Division Codegen

**Problem:** The codegen uses Erlang `:div` for all `/` operations, which crashes on float operands. Should use `/` for float division and `div` for integer division.

**Scope:**
- Check operand types in `generate_expr(%AST.BinaryOp{op: :slash})`
- Use `:erlang.'/'` for float operands, `:erlang.div` for integer operands
- When types are unknown, default to `/` (Erlang's `/` works on both but returns float)

**Files:**
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex`
- `apps/skein_compiler/test/skein/codegen/core_erlang_test.exs`

---

### 11. Fix Multiple `emit` in a Single Handler

**Problem:** Multiple `emit` calls in sequence only keep the last event because codegen overwrites the events list instead of accumulating.

**Scope:**
- Thread an accumulator for emitted events through handler body codegen
- Return the full list of events from the handler, not just the last one

**Files:**
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex`
- `apps/skein_compiler/test/skein/codegen/core_erlang_test.exs`

---

## Tier 3: Moderate (Spec/Implementation Drift)

### 12. Make Contextual Keywords Non-Reserved

**Problem:** `input`, `output`, `errors`, `state`, `strategy`, `child`, `description`, `policy`, `given`, `expect`, `assert`, `replay` are reserved globally but only meaningful in specific contexts. You can't name a variable `input` anywhere.

**Scope:**
- Change the lexer to emit these as `:ident` tokens
- Have the parser recognize them contextually (e.g., only treat `input` as a keyword inside a `tool` block)

---

### 13. `queue.consume` vs `queue.in` Naming

**Problem:** The spec uses `capability queue.consume("...")` but the implementation uses `capability queue.in`. The first principles document uses `queue.consume`.

**Scope:**
- Rename `queue.in` to `queue.consume` in the analyzer
- Similarly rename `schedule.in` to `schedule.trigger` or keep as-is (it's not in the spec either way)
- Update all tests and examples

---

### 14. Agent `emit` Events to EventStore

**Problem:** Events emitted via `emit` inside agents are stored in `gen_statem` data but not appended to the EventStore. If the agent crashes, emitted events are lost.

**Scope:**
- After each phase handler completes, flush accumulated events to EventStore
- Or: emit to EventStore inline during phase execution

---

### 15. Persistent EventStore Backend

**Problem:** The EventStore is ETS-only. All traces and events vanish on BEAM restart.

**Scope:**
- Add an optional persistent backend (SQLite via Ecto, or append-only file)
- Keep ETS as the fast path, flush to persistent storage asynchronously
- This enables production-grade trace inspection and golden test workflows

---

### 16. Schedule Handler Auto-Firing

**Problem:** Schedule handlers register their cron expression but never fire automatically. Only manual `trigger/1` works.

**Scope:**
- Add a timer in `Skein.Runtime.Schedule` that evaluates cron expressions against the current time
- Fire matching handlers at the appropriate intervals

---

## Completed Work (Reference)

All of the following are done and tested:

- Phases 1-7: Full compilation pipeline (lexer, parser, analyzer, codegen)
- Phase 8a: Test infrastructure (scenario, golden, replay)
- Phase 8b: Storage backend (Ecto + SQLite3)
- Phase 8c: HTTP server (Bandit + Plug)
- Phase 8d: Canonical examples (11 `.skein` files)
- Phase 8e: Queue and schedule handlers
- Phase 8f: LLM streaming
- Phase 10: Unified event store
- Standard library: 11 modules, 101 functions
- Error code alignment: 21 error + 3 warning codes
- suspend/resume, respond.text/html, topic pub/sub, idempotent, trace.annotate, llm.embed
- process.spawn, timer, event.log capabilities
- LSP: completions, hover, diagnostics, semantic tokens, document symbols
- CLI: new, build, test, run, trace commands
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/
