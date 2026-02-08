---
title: Roadmap
description: What's been built, what's next, and the full 7-phase implementation plan.
---

## Phase Status

| Phase | Name | Status | Summary |
|-------|------|--------|---------|
| 1 | Hello BEAM | **Complete** | End-to-end compilation pipeline |
| 2 | Type System Foundation | **Complete** | Type checking, schemas, constraint annotations |
| 3 | Capabilities and Effects | **Complete** | Capability declarations, effect calls, runtime enforcement, traces |
| 4 | Handlers and HTTP Server | **Complete** | HTTP handlers, routing, request dispatch, web server |
| 5 | Storage | **Complete** | ETS-backed `store.table` with get, put, delete, query |
| 6 | Agents | **Complete** | Agent skeleton, memory, LLM, tools, events |
| 7 | Testing, Replay, and CLI | **Complete** | Test constructs, full CLI (new, build, test, run, trace) |
| 8a | Test Infrastructure | **Complete** | Scenario, golden, replay test constructs |
| 8c | HTTP Server | **Complete** | Bandit + Plug, `req.json[T]` body validation |
| 8d | Canonical Examples | **Complete** | 5 working `.skein` programs with integration tests |
| 8e | Queue & Schedule Handlers | **Complete** | Event-driven and cron-triggered execution |
| 8f | LLM Streaming | **Complete** | `llm.stream` with chunked responses and trace spans |
| 8b | Storage Backend | **Next** | Ecto integration, Postgres/SQLite |

**Current test suite:** 76 properties, 742 tests, 0 failures

## Phase 1: Hello BEAM (Complete)

**Goal:** Prove the compilation pipeline works end-to-end.

**What was built:**
- Hand-written lexer with NimbleParsec (~441 lines, 69 unit tests, 11 property tests)
- Recursive descent parser with Pratt-style precedence climbing (~1200 lines, 47 unit tests, 8 property tests)
- Core Erlang code generator using `:cerl` module (~480 lines, 18 integration tests, 9 property tests)
- Full AST node definitions (20+ node types with source location tracking)
- Structured error type with JSON serialization
- Compiler entry point with `compile_string/1` and `compile_file/1`

**Acceptance criteria met:**
- `hello.skein` compiles to BEAM bytecode
- `greet("World")` returns `"Hello, World!"`
- `add(3, 4)` returns `7`
- `classify(-1)` returns `"non-positive"`

**Key decisions made:**
- Token format: `{:keyword, {line, col}}` tuples
- Variable naming: snake_case to CamelCase for Core Erlang
- String interpolation: compiles to `erlang:iolist_to_binary/1` over iolist
- Module naming: `Elixir.Skein.User.<Name>` for Elixir interop
- Compiler return: `{:module, mod}` (matching `:code.load_binary` return)

## Phase 2: Type System Foundation (Complete)

**Goal:** Named types, enums, type checking at function boundaries, and JSON schema derivation.

**What was built:**
- Type checker in the analyzer (Pass 2): validates function return types, operator types, match arm consistency
- `type` and `enum` declaration parsing and validation
- `Option[T]` and `Result[T, E]` as built-in parameterized types
- `!` (unwrap) and `?` (propagate) operators for Result handling
- JSON schema derivation: `type` declarations generate JSON Schema with `@min`, `@max`, `@one_of`, `@default` constraints
- Match exhaustiveness checking (warns on non-exhaustive boolean matches)
- Function call arity checking

**Error codes added:**
- E0010: Unknown identifier
- E0011: Unknown type reference
- E0012: Wrong function call arity
- E0020: Type mismatch
- E0021: Operator type error
- E0024: Non-exhaustive match (warning)
- E0025: Invalid constraint annotation

## Phase 3: Capabilities and Effects (Complete)

**Goal:** Capability declarations, compile-time capability checking, and the first effectful operations.

**What was built:**

### Compiler
- Capability checking pass (Analyzer Pass 3): walks function bodies to find effect calls and verifies covering capabilities
- Effect call codegen: `http.get(url)` compiles to `Skein.Runtime.Http.get(url, capabilities)` instead of a local function apply
- `__capabilities__/0` function generated in every compiled module, returning capability metadata as a list of maps

### Runtime (3 new modules)
- `Skein.Runtime.Http`: HTTP client wrapping Erlang's `:httpc` with capability enforcement and automatic tracing
- `Skein.Runtime.Capability`: URL host extraction and validation against declared capability hosts
- `Skein.Runtime.Trace`: ETS-based trace span recording with timing, metadata, and `with_span/2` instrumentation

**Error codes added:**
- E0030: Missing capability for effect call (with `fix_code` for agent auto-fix)

**Acceptance criteria met:**
- Module calling `http.get` without `capability http.out(...)` fails to compile with structured error
- Error includes `fix_code: "capability http.out"`
- Module with correct capabilities compiles and HTTP calls execute at runtime
- Runtime blocks HTTP to undeclared hosts (second layer of defense)
- Each HTTP call produces a trace span with timing and status

## Phase 4: Handlers and HTTP Server (Complete)

**Goal:** HTTP handlers with routing, request/response handling, and a running web server.

**What was built:**

### Compiler
- `handler http METHOD "/path/:param" (req) -> { ... }` syntax: parsing, analysis, codegen
- Handler metadata generation: `__handlers__/0` returns handler definitions with methods, routes, and parameter names
- Handler function codegen: compiles handler bodies with request parameter binding
- Route parameter extraction from path patterns

### Runtime (2 new modules)
- `Skein.Runtime.Handler`: Route matching with path parameters, HTTP method dispatch, request construction, JSON response encoding, trace recording
- `Skein.Runtime.Server`: GenServer-based TCP server with HTTP parsing, handler dispatch, and trace endpoint (`GET /__skein/traces`)

**Acceptance criteria met:**
- Handler declarations compile to callable functions with proper metadata
- Route parameters are extracted and available in the request map
- The HTTP server accepts connections and dispatches to compiled handlers
- Trace data is queryable via the debug endpoint

## Phase 5: Storage (Complete)

**Goal:** `store.table` operations with capability enforcement and tracing.

**What was built:**

### Compiler
- Store effect recognition: `store.<table>.<operation>(args)` pattern matching in analyzer and codegen
- Store capability checking: `capability store.table("tablename")` validated against store effect calls
- Store codegen: compiles store calls to `Skein.Runtime.Store` with table name, args, and capabilities

### Runtime (1 new module)
- `Skein.Runtime.Store`: ETS-backed storage with `get`, `put`, `delete`, `query` operations, capability enforcement, and automatic trace recording

**Acceptance criteria met:**
- Store operations compile and execute against ETS tables at runtime
- Store calls without `capability store.table(...)` fail to compile
- Each store operation produces a trace span
- Query operations support filter functions

## Phase 6: Agents (Complete)

**Goal:** The agent construct -- state machines with phases, transitions, memory, LLM calls, and tool calling. This is the crown jewel.

### Phase 6a: Agent Skeleton (Complete)

**What was built:**

#### Compiler
- `agent` declaration parsing: Phase enum with `->` transitions, state fields, `on start` / `on phase` handlers
- Agent analysis: name resolution of Phase variants and state fields, type checking, capability checking in handlers
- Transition checking (Analyzer Pass 4): validates `transition(Phase)` calls against declared transitions in the Phase enum
- Agent code generation: compiles agents to `Elixir.Skein.Agent.<Name>` modules with `start_link/1`, `__phases__/0`, `__start_handler__/2`, `__phase_handler__/3`
- `transition()`, `stop()`, `emit()`, `state.field` access compiled to handler return tuples

#### Runtime (1 new module)
- `Skein.Runtime.Agent`: GenStateMachine wrapper with `start/2`, `start_link/2`, `get_phase/1`, `get_state/1`, `get_events/1`
- Phase transition dispatch via `:gen_statem` internal events
- State merging and event accumulation across transitions

**Error codes added:**
- E0040: Invalid phase transition (with `fix_hint` listing valid transitions)

**Acceptance criteria met:**
- Agent declarations compile to GenStateMachine modules
- Phase transitions execute at runtime with proper state management
- Invalid transitions are caught at compile time with structured errors
- `emit()` appends events, `stop()` terminates the agent, `state.field` accesses agent state

### Phase 6b: Memory and LLM (Complete)

**What was built:**

#### Compiler
- `memory.*` effect recognition: `memory.put`, `memory.get`, `memory.delete`, `memory.list`
- `llm.*` effect recognition: `llm.chat`, `llm.json`
- Capability checking for `memory.kv` and `model` capabilities
- Code generation for memory and LLM effect calls to runtime module calls

#### Runtime (2 new modules)
- `Skein.Runtime.Memory`: scoped KV storage with per-namespace ETS tables (`skein_memory_<namespace>`), capability enforcement, and trace recording
- `Skein.Runtime.Llm`: provider-agnostic LLM client with `chat/4` and `json/5`, pluggable backend system, structured `Llm.Error` type with 8 error kinds
- `Skein.Runtime.Llm.Backend` behaviour for custom providers
- `Skein.Runtime.Llm.TestBackend` for deterministic testing

**Acceptance criteria met:**
- Memory operations compile and execute with namespace scoping
- Memory calls without `capability memory.kv(...)` fail to compile
- LLM calls compile and dispatch to the active backend
- LLM calls without `capability model(...)` fail to compile
- Schema-constrained JSON responses are parsed and validated
- All memory and LLM operations produce trace spans

### Phase 6c: Tools and Events (Complete)

**What was built:**

#### Compiler
- `tool` declaration parsing: dotted names, input/output fields with annotations, errors block, implement body
- Tool metadata generation: `__tools__/0` returns tool definitions with name, description, field metadata, and JSON Schema
- `tool.call`, `tool.list`, `tool.schema` effect codegen
- `emit` expression codegen for domain events
- `llm.json[T]` type-parameterized call syntax: parser support for `[TypeExpr]` in postfix position
- Compile-time JSON Schema derivation from type declarations for `llm.json[T]`
- `SchemaGen.fields_to_schema/1` for generating JSON Schema from field lists

#### Runtime (1 new module)
- `Skein.Runtime.Tool`: Tool registry with `register/3`, `call/3`, `list/2`, `schema/3`, capability enforcement, structured `Tool.Error` type, and automatic trace recording

**Acceptance criteria met:**
- Tool declarations compile with full metadata including JSON Schema
- `tool.call` executes registered tools and traces the calls
- `llm.json[T]` passes compiled schema to the LLM runtime
- `llm.json` without type parameter still works (backward compatible)
- All tool operations produce trace spans

### Phase 6: Deferred Features (Post-MVP)

These Phase 6 features were intentionally deferred — the core agent runtime is complete:

- Agent pool supervision (`AgentPool` with max concurrency)
- `suspend()` / `resume()` lifecycle
- Tool policies (rate limits, approval workflows)

## Phase 7: Testing, Replay, and CLI (Complete)

**Goal:** Built-in test constructs and a complete CLI for project management.

**What was built:**

### Compiler
- `test "description" { ... }` -- parsing, codegen to `__test_N__/0` functions, `__tests__/0` metadata
- `assert expr` -- evaluates expression, raises `RuntimeError` on falsy

### CLI (5 new commands, 34 new tests)
- `Skein.CLI.new/1` -- scaffold a new project with `skein.toml`, `src/main.skein`, `test/main_test.skein`, and `README.md`
- `Skein.CLI.build/1` -- compile all `.skein` files in a project's `src/` tree; reports per-file success/failure
- `Skein.CLI.test/1` -- compile and run tests in a single `.skein` file
- `Skein.CLI.test_all/1` -- discover and run all tests across `src/` and `test/` directories with aggregate reporting
- `Skein.CLI.run/1` -- compile a project and start an HTTP server for handler modules (`--port` flag)
- `Skein.CLI.trace/1` -- view recent trace spans with `--last` and `--kind` filters

### Mix Aliases
- `mix skein.new` / `mix skein.build` / `mix skein.test` / `mix skein.run` / `mix skein.trace`

**Acceptance criteria met:**
- `skein new my_service` generates a working project with compilable example files
- `skein build` compiles all `.skein` files and reports results
- `skein test` discovers tests across directories, aggregates pass/fail/compile-error counts
- `skein run` starts the HTTP server and serves compiled handlers
- `skein trace --last 10` returns recent trace spans

## Phase 8: Hardening and Infrastructure

Filling gaps in the existing implementation and proving the full language works end-to-end.

- **8a: Test infrastructure** -- ✅ `scenario` tests with `given`/`expect`, `golden` trace tests, replay engine
- **8b: Storage backend** -- Ecto schema generation, migrations, SQLite/Postgres backends
- **8c: HTTP server** -- ✅ Bandit + Plug integration with `req.json[T]` body validation
- **8d: Canonical examples** -- ✅ `hello_http.skein`, `refund_agent.skein`, `incident_triage.skein`, `queue_worker.skein` with integration tests
- **8e: Queue and schedule handlers** -- ✅ `handler queue` and `handler schedule` constructs with full pipeline support

### Phase 8d: Canonical Examples

Four canonical `.skein` programs demonstrating different language features:

| Example | Demonstrates |
|---------|-------------|
| `hello_http.skein` | HTTP handlers, route parameters, multiple endpoints |
| `refund_agent.skein` | Agent lifecycle, phase transitions, memory, LLM |
| `incident_triage.skein` | Multi-phase agent, classification, escalation |
| `queue_worker.skein` | Mixed handler types (HTTP, queue, schedule) |

All examples compile successfully and have integration tests verifying their behavior.

### Phase 8e: Queue and Schedule Handlers

**Parser:** Extended `parse_handler` to branch on handler source: `http`, `queue`, or `schedule`. Queue handlers parse a queue name and message parameter. Schedule handlers parse a cron expression and optional parameter.

**Analyzer:** Generalized capability checking to require `queue.in` for queue handlers and `schedule.in` for schedule handlers (alongside existing `http.in` for HTTP handlers). Error E0030 is produced for missing capabilities.

**CodeGen:** Handler metadata in `__handlers__/0` now includes a `source` field (`:http`, `:queue`, `:schedule`). Schedule handlers with no parameters compile with a discard variable.

**Runtime:** Two new modules:
- `Skein.Runtime.Queue` -- GenServer-based message queue dispatch with subscribe/publish
- `Skein.Runtime.Schedule` -- Cron-based scheduling with register/trigger and cron expression parsing

**Tests:** 24 new unit tests, 2 new property tests covering all handler types across parser, analyzer, codegen, and runtime.

### Phase 8f: LLM Streaming (Complete)

**Goal:** Support streaming LLM responses for real-time agent output.

**What was built:**

**Compiler:**
- Added `"stream"` to the analyzer's known LLM effect methods -- uses the same `model` capability as `llm.chat` and `llm.json`
- CodeGen emits `Skein.Runtime.Llm.stream(model, system, input, noop_callback, capabilities)` for `llm.stream(...)` calls
- Compiled code passes a no-op callback; runtime callers can pass custom callbacks for chunk processing

**Runtime:**
- `Skein.Runtime.Llm.stream/5` -- streams chunks via an `on_chunk` callback, assembles and returns full response
- `Backend` behaviour extended with optional `stream/3` callback
- 4 new test backends: `StreamingTestBackend`, `EmptyStreamBackend`, `FailingStreamBackend`, `DynamicStreamBackend`
- Dynamic backends via `{module, config}` tuples for property testing with configurable chunk lists
- Trace spans with `:stream` method, model, timing, and outcome metadata

**Tests:** 7 new unit tests, 4 new property tests, 2 new analyzer tests, 3 new codegen tests, 3 new integration tests

**Acceptance criteria met:**
- `llm.stream` compiles and runs end-to-end from `.skein` source
- Streaming uses the same `model` capability as `llm.chat` and `llm.json`
- All chunks are delivered in order and the response is correctly assembled
- Each streaming call produces a trace span
- Property tests verify: chunk reassembly equals concatenation, chunk ordering, capability enforcement, trace recording

### Phase 8 Remaining

- **8b: Storage backend** -- Ecto schema generation, migrations

See the [Implementation Plan](https://github.com/kormie/Skein/blob/main/docs/IMPLEMENTATION_PLAN.md) for full acceptance criteria.

## Post-MVP Backlog

- Erlang/Elixir FFI (`extern`)
- Hot code upgrades
- Web IDE (trace viewer)
- Language Server Protocol (LSP)
- `llm.embed` and `llm.rerank` for RAG
- Human-in-the-loop approval workflows
- Managed deployment platform
- Marketplace for tools/connectors
