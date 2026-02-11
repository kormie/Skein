# Skein Roadmap

**As of:** 2026-02-11
**Based on:** `docs/AUDIT_FIRST_PRINCIPLES.md`

This is the forward-looking work list for Skein. Items are ordered by impact -- the top items close the biggest gaps between the language's stated goals and its current reality.

Every item is self-contained. Pick the top incomplete one and work it.

**Every item requires:**
- TDD -- tests first, implementation second
- Property tests where input spaces are wide (StreamData for pure, PropCheck for stateful)
- Update `docs/ARCHITECTURE.md` and `docs/SKEIN_SPEC.md` if behavior changes

**Sizing key:** S = a few hours, M = half a day, L = a full day, XL = multiple days

---

## Current State

The compilation pipeline works end-to-end. Lexer, parser, analyzer, codegen, and runtime are functional. 1,176 tests + 182 property tests pass. 11 example `.skein` files compile and run. The LSP, CLI, and docs site are operational.

The biggest gaps are in the type system (most expressions infer to `:unknown`), spec-example alignment (canonical examples use unimplemented syntax), and runtime capability enforcement (4 of 9 subsystems don't check capabilities at all).

---

## Tier 1: Critical (Undermines Core Promises)

### 1. Real Type Inference for Field Access and Pattern Bindings `[XL]`

**Problem:** `infer_type(%AST.FieldAccess{}, _env)` returns `{:unknown, []}` (analyzer.ex:1230). Pattern variables bind as `:unknown` (analyzer.ex:1282). This means `user.email + 42` compiles without error. The "Types Are Contracts" principle (P3) is not delivered.

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
- Property: for any user type with N fields, accessing each field returns the declared type
- All existing tests still pass

**Depends on:** Nothing. Start here.

---

### 2. Schema Derivation for Nested Types and Enum Variants `[L]`

**Problem:** `type Order { customer: Customer }` generates `{"type": "object"}` for the `customer` field instead of inlining `Customer`'s schema (schema_gen.ex falls through to the catch-all at line ~127). Data-carrying enum variants lose their field information. `Map[K, V]` loses type parameters.

**Scope:**
- `SchemaGen.type_to_schema/1`: add a clause for `{:user_type, name}` that looks up the type declaration and recursively generates its schema (currently falls through to `%{"type" => "object"}`)
- Enum variants with fields: generate `oneOf` with each variant as an object schema
- `Map[K, V]`: generate `additionalProperties` from the value type
- `List[T]`: generate `items` from the element type (already works for built-in T, extend to user types)
- Handle circular type references with a `seen` set to prevent infinite recursion

**Files:**
- `apps/skein_compiler/lib/skein/codegen/schema_gen.ex`
- `apps/skein_compiler/test/skein/codegen/schema_gen_test.exs`

**Acceptance criteria:**
- Nested user type generates fully resolved JSON Schema
- `enum Event { Charge(amount: Int) }` generates `oneOf` with variant schemas
- `Map[String, Int]` generates `{"type": "object", "additionalProperties": {"type": "integer"}}`
- Tool manifests with nested types produce complete, valid schemas
- Circular type references don't stack overflow
- Property: for any generated schema, it validates against JSON Schema meta-schema

**Depends on:** Item 1 (type inference provides the resolved type environment that schema gen needs to look up user types).

---

### 3. Align Spec Examples with Implementation `[XL]`

**Problem:** The canonical examples in `SKEIN_SPEC.md` sections 8.2-8.5 use syntax that doesn't exist: object literals (`{ "error": "not found" }`), named arguments (`model: "..."`), tuple destructuring, unit type `()`, anonymous functions in stubs, and `agent.run_sync()`. An LLM given the spec will generate code that doesn't compile.

**Two paths -- take a hybrid approach:**

**Implement (Path A):** Map literals and named arguments. These are fundamental data construction syntax that any non-trivial Skein program needs. Without map literals, there is no way to return structured data from handlers.
- Add map literal parsing: `{ key: value, ... }` to lexer + parser + codegen
- Add named argument parsing: `fn(name: value, ...)` to parser + codegen
- Map literal AST node already exists (`AST.MapLiteral`) -- parser support is missing

**Rewrite (Path B):** Everything else. `agent.run_sync()`, `stubs: { ... }`, tuple destructuring, and unit type can be deferred.
- Rewrite sections 8.2-8.5 to use only implemented syntax for features not in Path A
- Replace `agent.run_sync()` with the actual `Agent.start/2` + `Agent.get_phase/1` test pattern
- Mark deferred features clearly as "Planned"

**Files:**
- `apps/skein_compiler/lib/skein/lexer.ex` -- `{`, `}`, `:` token handling in map context
- `apps/skein_compiler/lib/skein/parser.ex` -- `parse_map_literal`, `parse_named_args`
- `apps/skein_compiler/lib/skein/ast.ex` -- `MapLiteral` node already exists
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` -- map literal codegen
- `docs/SKEIN_SPEC.md` -- sections 8.2-8.5

**Acceptance criteria:**
- `{ name: "Alice", age: 30 }` parses, analyzes, compiles, and returns a map at runtime
- `handler http GET "/users" (req) -> { { status: 200, users: store.users.query() } }` works end-to-end
- Every example in `SKEIN_SPEC.md` section 8 either compiles successfully or is clearly annotated as "Planned"
- Rewritten examples have integration tests proving they compile and run

**Depends on:** Nothing, but benefits from item 1 (type inference makes map field access type-safe).

---

### 4. Runtime Capability Enforcement `[L]`

**Problem:** 4 of 9 runtime effect subsystems ignore capabilities entirely. Tool and LLM checks are presence-only (any `tool.use` or `model` capability passes, regardless of the specific tool/model named). Verified in source:
- `tool.ex`: `check_tool_capability` filters on `cap.kind == "tool.use"` but never inspects the tool name
- `llm.ex`: `check_model_capability` filters on `cap.kind == "model"` but ignores provider/model params
- `topic.ex`: `publish/3` takes `_capabilities` (underscore = unused)
- `process.ex`, `timer.ex`, `event_store.ex`: same pattern

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
- `apps/skein_runtime/lib/skein/runtime/tool.ex` -- `check_tool_capability/1`
- `apps/skein_runtime/lib/skein/runtime/llm.ex` -- `check_model_capability/2`
- `apps/skein_runtime/lib/skein/runtime/topic.ex` -- `publish/3`
- `apps/skein_runtime/lib/skein/runtime/process.ex`
- `apps/skein_runtime/lib/skein/runtime/timer.ex`
- `apps/skein_runtime/lib/skein/runtime/event_store.ex`
- Corresponding test files for each

**Acceptance criteria:**
- `tool.call(Stripe.Refund, ...)` with `capability tool.use(Slack.PostMessage)` raises `CapabilityViolation`
- `llm.chat("openai", "gpt-4", ...)` with `capability model("anthropic", "claude-sonnet-4-5")` raises `CapabilityViolation`
- `topic.publish("orders", ...)` with `capability topic.publish("billing")` raises `CapabilityViolation`
- `process.spawn(MyAgent, ...)` without `capability process.spawn(MyAgent)` raises `CapabilityViolation`
- `timer.after(...)` without `capability timer` raises `CapabilityViolation`
- `event.log("orders", ...)` with `capability event.log("billing")` raises `CapabilityViolation`
- Property: for each subsystem, a randomized capability set either permits or denies based on exact name match
- All existing tests still pass

**Depends on:** Nothing. Can be done in parallel with items 1-3.

---

## Tier 2: Serious (Significant Functionality Gaps)

### 5. Fix Agent Stateful Test (`agent_statem_test.exs`) `[S]`

**Problem:** The PropCheck stateful test for agent lifecycle exists at `apps/skein_runtime/test/skein/runtime/agent_statem_test.exs` with proper state machine model (StateParkAgent, StateTwoPhaseAgent, StateStopAgent), but it calls `Skein.Compiler.compile_string/1` from `skein_runtime`, which doesn't depend on `skein_compiler`.

**Scope:**
- Option A (preferred): Add `{:skein_compiler, in_umbrella: true, only: :test}` to `skein_runtime/mix.exs` deps
- Option B: Move the test file to `apps/skein_compiler/test/skein/integration/agent_statem_test.exs`
- Verify the three PropCheck models (park, two-phase, stop) all pass

**Files:**
- `apps/skein_runtime/test/skein/runtime/agent_statem_test.exs`
- `apps/skein_runtime/mix.exs` (add test dep)

**Acceptance criteria:**
- `mix test apps/skein_runtime/test/skein/runtime/agent_statem_test.exs` passes
- All three agent models exercise full lifecycle through PropCheck
- No umbrella dependency issues in CI

**Depends on:** Nothing.

---

### 6. Agent Instance-Scoped Memory `[M]`

**Problem:** The first principles (Section 6.3) promise memory is "implicitly scoped to the agent instance" with keys stored as `RefundAgent:<instance_id>:decision`. In reality, memory uses the declared namespace without instance scoping. Two concurrent agent instances sharing a `memory.kv` namespace will overwrite each other.

**Scope:**
- In `Skein.Runtime.Agent`, inject a unique instance ID (e.g., `Uuid.new()`) into the agent's `gen_statem` data at `init/1`
- When an agent process calls `memory.put/get/delete`, prepend `{agent_name}:{instance_id}:` to the key
- This scoping should be transparent -- the agent code writes `memory.put("decision", d)` and gets automatic scoping
- `memory.list` must filter to keys matching the current agent's prefix

**Files:**
- `apps/skein_runtime/lib/skein/runtime/agent.ex` -- `init/1`, state structure
- `apps/skein_runtime/lib/skein/runtime/memory.ex` -- `put/4`, `get/3`, `delete/3`, `list/2`
- `apps/skein_runtime/test/skein/runtime/memory_test.exs` -- concurrent agent isolation tests
- `apps/skein_runtime/test/skein/runtime/agent_test.exs` -- end-to-end memory scoping

**Acceptance criteria:**
- Two concurrent `RefundAgent` instances write to the same key without interference
- `memory.get("decision")` returns only the current instance's value
- `memory.list("*")` returns only the current instance's keys
- Property: N concurrent agent instances with M random memory operations never observe each other's state

**Depends on:** Nothing.

---

### 7. Replay Engine -- Actual Replay `[L]`

**Problem:** `Skein.Runtime.Replay` reads traces and reconstructs memory (`load_trace/1`, `replay/1`, `rebuild_memory/2`), but cannot inject recorded responses into a live execution. The three modes (recorded/live/hybrid) described in the first principles are not functional.

**Scope:**
- Implement recorded-mode replay: override LLM, HTTP, and tool backends with recorded responses during replay
- Use process dictionary or a GenServer to hold the replay state (event sequence + cursor position)
- Match replay events by kind + sequence position
- Return recorded results instead of executing real effects
- Integrate with the existing `Backend` behaviour for LLM (inject a `ReplayBackend`)

**Files:**
- `apps/skein_runtime/lib/skein/runtime/replay.ex` -- add `start_replay/2`, `with_replay/2`
- `apps/skein_runtime/lib/skein/runtime/llm.ex` -- support replay backend injection
- `apps/skein_runtime/lib/skein/runtime/http.ex` -- support replay response injection
- `apps/skein_runtime/test/skein/runtime/replay_test.exs`

**Acceptance criteria:**
- Given a recorded trace of an agent run, `Replay.start_replay(trace, :recorded)` re-executes the agent and produces identical results without making real LLM/HTTP calls
- Out-of-sequence events produce a clear error (not a silent mismatch)
- The existing `load_trace/1` and `rebuild_memory/2` continue to work
- Replay state is process-scoped (no global contamination between concurrent replays)

**Depends on:** Nothing, but works best after item 8 (production LLM backend produces real traces to replay).

---

### 8. Production LLM Backend `[L]`

**Problem:** The LLM client has 7 test backends but zero HTTP backends. No real LLM provider can be called.

**Scope:**
- Implement `Skein.Runtime.Llm.AnthropicBackend` implementing the `Backend` behaviour
- HTTP client via Erlang's `:httpc` (already used by `Skein.Runtime.Http`)
- Handle API key from environment variable (`ANTHROPIC_API_KEY`)
- Support `chat/3`, `json/4` (schema in system prompt), `stream/3`, and `embed/2`
- Retry on 429 rate limits with `retry-after` from response headers
- Map Anthropic error responses to `Llm.Error` struct

**Files:**
- `apps/skein_runtime/lib/skein/runtime/llm/anthropic_backend.ex` (new)
- `apps/skein_runtime/test/skein/runtime/llm/anthropic_backend_test.exs` (new, with recorded responses via bypass or static fixtures)

**Acceptance criteria:**
- `Llm.set_backend(Skein.Runtime.Llm.AnthropicBackend)` followed by `Llm.chat("anthropic", "system prompt", "user input", caps)` makes a real HTTP request to `api.anthropic.com`
- `llm.json` passes the schema as a JSON Schema constraint in the system prompt and parses the response
- `llm.stream` delivers chunks via the `on_chunk` callback
- 429 responses trigger up to 3 retries with exponential backoff
- Tests use recorded HTTP responses (no live API calls in CI)
- Error responses produce structured `Llm.Error` values

**Depends on:** Nothing.

---

### 9. Populate Error `context` and Expand `fix_code` `[M]`

**Problem:** The `context` field on `Skein.Error` is always `nil`. `fix_code` is only present on 5 of 24 error codes (E0012, E0014, E0030, E0032, W0001). This weakens the LLM self-correction loop that is central to Skein's design.

**Scope:**
- Thread source text through the analyzer (pass it in the initial environment or read from `meta.file`)
- Extract the relevant source line(s) for each error using the error's `location` field
- Populate `context` with the source expression that triggered the error
- Add `fix_code` to the highest-impact error codes:
  - E0020 (type mismatch): suggest the correct type or cast
  - E0010 (undefined identifier): suggest the closest defined name (Levenshtein or substring match)
  - E0030 (invalid transition): suggest valid transitions from the current phase
  - E0022/E0023 (invalid `!`/`?`): wrap in `match` or convert to `Result`
  - E0021 (non-exhaustive match): add missing arms

**Files:**
- `apps/skein_compiler/lib/skein/analyzer.ex` -- all `add_error` call sites
- `apps/skein_compiler/lib/skein/error.ex` -- `context` population helper
- `apps/skein_compiler/test/skein/analyzer_test.exs` -- verify `context` and `fix_code` on errors

**Acceptance criteria:**
- Every error produced by the analyzer includes a non-nil `context` (the source line)
- `fix_code` is present on at least E0020, E0010, E0030, E0022, E0023, E0021
- `fix_code` values are syntactically valid Skein (they should compile if applied)
- JSON serialization of errors includes both new fields

**Depends on:** Nothing.

---

### 10. Fix Division Codegen `[S]`

**Problem:** The codegen maps `/` to Erlang `:div` unconditionally (`erlang_op(:/) -> :div` at core_erlang.ex:2027). `:div` crashes on float operands (`** (ArithmeticError) bad argument in arithmetic expression`).

**Scope:**
- In `generate_expr(%AST.BinaryOp{op: :slash})`, check operand types from the analyzer annotation (or infer from literal values)
- Use `:erlang.'/'` for float operands (returns float), `:erlang.div` for integer operands (returns integer)
- When both types are `:unknown`, default to `:erlang.'/'` (Erlang's `/` works on both int and float but always returns float)

**Files:**
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` -- `erlang_op/1` and `generate_expr` for `:slash`
- `apps/skein_compiler/test/skein/codegen/core_erlang_test.exs`

**Acceptance criteria:**
- `10 / 3` returns `3` (integer division)
- `10.0 / 3.0` returns `~3.333` (float division)
- `10 / 3.0` returns `~3.333` (mixed: float division)
- Existing arithmetic tests still pass
- Property: for any two non-zero numbers, division produces a valid numeric result (no crash)

**Depends on:** Benefits from item 1 (type inference lets codegen know the operand types without guessing).

---

### 11. Fix Multiple `emit` in a Single Handler `[M]`

**Problem:** Multiple `emit` calls in a handler sequence may lose events. The codegen generates `emit` as side-effecting let-expressions, but the handler return value only carries the last event set. The `gen_statem` data accumulates events across transitions but within a single handler body, the events list in the return tuple is overwritten rather than appended.

**Scope:**
- Thread an accumulator for emitted events through handler body codegen
- Each `emit` call appends to the accumulator instead of replacing it
- The handler return tuple includes the complete accumulated events list
- Verify that agent `get_events/1` returns all emitted events in order

**Files:**
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` -- handler body generation, emit codegen
- `apps/skein_compiler/test/skein/codegen/core_erlang_test.exs`
- `apps/skein_compiler/test/skein/examples_test.exs` -- integration test with multi-emit handler

**Acceptance criteria:**
- A handler with `emit("a"); emit("b"); emit("c")` produces events `["a", "b", "c"]` (all three, in order)
- An agent handler with multiple `emit` calls followed by `transition` preserves all events
- Property: for N emit calls in a handler, exactly N events appear in `get_events/1`

**Depends on:** Nothing.

---

### 12. Tool Input Validation `[M]`

**Problem:** Tool inputs go directly to the implementation function without schema validation. The `validation_error` variant exists in `Tool.Error` but is never constructed. An LLM calling a tool with malformed input gets a runtime crash instead of a structured error.

**Scope:**
- In `Tool.call/3`, validate the input map against the tool's registered JSON Schema before invoking the implementation
- Use the schema (already stored in the registry via `__tools__/0`) for validation
- On validation failure, return `{:error, %Tool.Error{kind: :validation_error, ...}}` with a message describing which fields are invalid
- This is the runtime counterpart of the compile-time type checking

**Files:**
- `apps/skein_runtime/lib/skein/runtime/tool.ex` -- `call/3`, add validation before `impl.(input)`
- `apps/skein_runtime/test/skein/runtime/tool_test.exs`

**Acceptance criteria:**
- `tool.call(MyTool, %{"amount" => "not_a_number"})` returns `{:error, %Tool.Error{kind: :validation_error}}` when the schema declares `amount: Int`
- Valid inputs pass through to the implementation unchanged
- Validation errors include the field name and expected type
- Property: for any tool schema and any random input map, validation either passes (conforming input) or produces a structured error (non-conforming input)

**Depends on:** Item 2 (schema derivation for nested types makes validation comprehensive).

---

## Tier 3: Moderate (Spec/Implementation Drift)

### 13. Make Contextual Keywords Non-Reserved `[M]`

**Problem:** 12 tokens are reserved globally but only meaningful in specific contexts: `input`, `output`, `errors`, `state`, `strategy`, `child`, `description`, `policy`, `given`, `expect`, `assert`, `replay`. You can't name a variable `input` anywhere in a Skein program, even though `input` is only meaningful inside a `tool` block. The lexer has 28 reserved keywords total.

**Scope:**
- Move the 12 contextual tokens out of the lexer's keyword list
- Emit them as `:ident` tokens instead
- In the parser, recognize them contextually:
  - `input`/`output`/`errors`/`description`/`policy` only inside `parse_tool`
  - `state`/`strategy`/`child` only inside `parse_supervisor`
  - `given`/`expect` only inside `parse_scenario`
  - `assert` only inside `parse_test`
  - `replay` only inside `parse_golden`

**Files:**
- `apps/skein_compiler/lib/skein/lexer.ex` -- keyword list
- `apps/skein_compiler/lib/skein/parser.ex` -- contextual recognition in each construct
- `apps/skein_compiler/test/skein/lexer_test.exs`
- `apps/skein_compiler/test/skein/parser_test.exs`

**Acceptance criteria:**
- `let input = "hello"` compiles successfully (outside a tool block)
- `tool MyTool { input { name: String } }` still works (inside a tool block, `input` is a keyword)
- `let state = 42` compiles successfully (outside a supervisor block)
- All existing `.skein` example files still compile
- Property: any valid identifier string that happens to be a contextual keyword works as a variable name outside its context

**Depends on:** Nothing.

---

### 14. `queue.consume` vs `queue.in` Naming `[S]`

**Problem:** The spec uses `capability queue.consume("...")` but the implementation uses `capability queue.in`. The first principles document uses `queue.consume`. Similarly, the spec doesn't mention `schedule.in`.

**Scope:**
- In the analyzer, rename `queue.in` -> `queue.consume` in `handler_required_capability/1`
- Rename `schedule.in` -> `schedule.trigger` for consistency
- Update the codegen handler metadata to use the new names
- Update all tests and example files
- Add a deprecation note if backward compatibility is needed (but since Skein is pre-1.0, a clean rename is fine)

**Files:**
- `apps/skein_compiler/lib/skein/analyzer.ex` -- `handler_required_capability/1`
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` -- handler metadata
- `apps/skein_compiler/test/` -- all queue/schedule tests
- `examples/queue_worker.skein`
- `docs/SKEIN_SPEC.md`

**Acceptance criteria:**
- `capability queue.consume("orders")` compiles and works
- `capability queue.in("orders")` produces a helpful error suggesting `queue.consume`
- All existing queue and schedule examples compile with the new names

**Depends on:** Nothing.

---

### 15. Agent `emit` Events to EventStore `[M]`

**Problem:** Events emitted via `emit` inside agents are stored in `gen_statem` data but not appended to the EventStore. If the agent crashes, emitted events are lost. The unified EventStore (Phase 10) exists but agents don't write to it.

**Scope:**
- After each phase handler completes in `Skein.Runtime.Agent`, flush the accumulated events to `EventStore.append/1`
- Tag events with the agent name, instance ID, and phase for queryability
- Keep the in-memory `get_events/1` API as-is (it reads from `gen_statem` data for fast access)
- The EventStore becomes the durable record; `gen_statem` data is the hot cache

**Files:**
- `apps/skein_runtime/lib/skein/runtime/agent.ex` -- `handle_event` for phase completion
- `apps/skein_runtime/lib/skein/runtime/event_store.ex` -- ensure `append/1` handles agent event format
- `apps/skein_runtime/test/skein/runtime/agent_test.exs`

**Acceptance criteria:**
- After an agent emits events and transitions, `EventStore.query(kind: :user_event)` includes those events
- If an agent crashes mid-execution, events emitted before the crash are in the EventStore
- `Agent.get_events/1` and `EventStore.query` return consistent data
- Property: for N events emitted across M phase transitions, exactly N events appear in the EventStore

**Depends on:** Nothing.

---

### 16. Persistent EventStore Backend `[L]`

**Problem:** The EventStore is ETS-only. All traces and events vanish on BEAM restart.

**Scope:**
- Add an optional persistent backend (SQLite via Ecto, reusing the existing `Skein.Runtime.Repo`)
- Keep ETS as the fast path for writes; flush to persistent storage asynchronously (write-behind)
- On startup, load recent events from the persistent store into ETS
- Configuration: `EventStore.configure(backend: :ets | :sqlite)`
- This enables production-grade trace inspection and golden test workflows across restarts

**Files:**
- `apps/skein_runtime/lib/skein/runtime/event_store.ex` -- backend abstraction
- `apps/skein_runtime/lib/skein/runtime/event_store/sqlite_backend.ex` (new)
- `apps/skein_runtime/lib/skein/runtime/migration_gen.ex` -- events table migration
- `apps/skein_runtime/test/skein/runtime/event_store_test.exs`

**Acceptance criteria:**
- With SQLite backend, events survive a BEAM restart
- Write throughput does not degrade more than 2x compared to ETS-only
- `EventStore.query/1` returns the same results regardless of backend
- Existing ETS-only behavior is the default (no breaking changes)

**Depends on:** Item 15 (agent emit to EventStore -- gives meaningful events to persist).

---

### 17. Schedule Handler Auto-Firing `[M]`

**Problem:** Schedule handlers register their cron expression but never fire automatically. Only manual `trigger/1` works.

**Scope:**
- Add a periodic timer (e.g., `:timer.send_interval/2` at 1-second granularity) in `Skein.Runtime.Schedule`
- On each tick, evaluate all registered cron expressions against the current time
- Fire matching handlers via the existing dispatch path
- Track last-fired time per handler to prevent duplicate firings within the same cron period
- Respect `strategy: :one_for_one` for crash recovery of scheduled handlers

**Files:**
- `apps/skein_runtime/lib/skein/runtime/schedule.ex` -- `init/1`, `handle_info` for timer ticks
- `apps/skein_runtime/test/skein/runtime/schedule_test.exs`

**Acceptance criteria:**
- A handler with `handler schedule "* * * * *" (tick)` fires once per minute without manual intervention
- A handler with `handler schedule "0 * * * *" (tick)` fires only at the top of each hour
- `trigger/1` still works for manual/test invocation
- No duplicate firings within the same cron period
- Property: for any valid cron expression and any time window, the number of firings matches the expected count

**Depends on:** Nothing.

---

### 18. Agent Nesting Inside Modules `[M]`

**Problem:** The spec (Section 8.4) shows `agent RefundAgent { ... }` nested inside `module RefundService { ... }`. But `parse_declaration` in the parser only handles: `fn`, `type`, `enum`, `capability`, `handler`, `tool`, `test`, `scenario`, `golden`, `supervisor`. Agents are not in this list. A module containing an agent fails to parse.

**Scope:**
- Add `{:agent, _}` clause to `parse_declaration` in the parser
- Route to the existing `parse_agent` function
- In codegen, handle nested agents by namespacing: `module Foo { agent Bar { ... } }` produces `Skein.Agent.Foo.Bar`
- Validate that nested agents can access module-level types and capabilities

**Files:**
- `apps/skein_compiler/lib/skein/parser.ex` -- `parse_declaration`
- `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` -- nested agent module naming
- `apps/skein_compiler/test/skein/parser_test.exs`
- `apps/skein_compiler/test/skein/codegen/core_erlang_test.exs`

**Acceptance criteria:**
- `module RefundService { agent RefundAgent { ... } }` parses successfully
- The nested agent compiles to `Skein.Agent.RefundService.RefundAgent`
- Types declared in the parent module are visible to the nested agent
- Capabilities declared at module level apply to the nested agent's handlers

**Depends on:** Nothing, but works best after item 3 (spec alignment provides the canonical example to validate against).

---

## Post-MVP Backlog

Items that are planned but not yet scoped or prioritized. These will be promoted to the tiered list as the items above are completed.

- Erlang/Elixir FFI (`extern` keyword) -- interop with existing BEAM libraries
- Hot code upgrades -- OTP release upgrades without downtime
- Web IDE / trace viewer -- browser-based exploration of trace data
- Human-in-the-loop approval workflows -- `suspend` before sensitive tool calls
- `llm.rerank` for RAG pipelines -- complement the existing `llm.embed`
- Guard expressions in match arms -- AST field exists but is always `nil`
- Managed deployment platform -- hosted Skein runtime
- Marketplace for tools/connectors -- shareable tool definitions

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
- LSP: completions, hover, diagnostics, semantic tokens, document symbols, go-to-definition
- CLI: new, build, test, run, trace commands
- Distribution: Burrito binaries (Linux x86_64, macOS x86_64, macOS ARM64), `skein build --output`
- Docs site: Astro + Starlight at https://kormie.github.io/Skein/
