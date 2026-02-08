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
| 6 | Agents | Planned | State machines, LLM calls, tool calling |
| 7 | Testing, Replay, and CLI | Planned | Built-in tests, trace replay, `skein` CLI |

**Current test suite:** 44 properties, 352 tests, 0 failures

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

## Phase 6: Agents (Next)

**Goal:** The agent construct -- state machines with phases, transitions, memory, LLM calls, and tool calling. This is the crown jewel.

**Planned scope:**
- `agent` declaration with `state`, `Phase` enum with transitions, `on start`, `on phase(...)` handlers
- Agent -> `gen_statem` compilation
- `transition(Phase)` with compile-time transition validation
- `suspend()` / `resume()` lifecycle
- `memory.put` / `memory.get` with automatic instance scoping
- `llm.json[T]` and `llm.chat` -- LLM client with schema-constrained decoding
- `tool` declarations with contract/implementation separation
- `tool.call` -- tool execution with tracing
- Agent pool supervision (`AgentPool` with max concurrency)
- `emit` for domain events

## Phase 7: Testing, Replay, and CLI (Planned)

**Planned scope:**
- `test "description" { ... }` construct
- `scenario` tests with `given`/`expect` blocks
- `golden` trace tests with `replay`
- Replay engine: re-execute handlers/agents against recorded I/O
- `skein new` -- project scaffolding
- `skein build` -- compile to OTP release
- `skein test` -- run all test types
- `skein run` -- start the service locally
- `skein trace` -- view recent traces (CLI table output)

## Post-MVP Backlog

- Queue/topic handlers
- Schedule handlers
- LLM streaming
- Erlang/Elixir FFI (`extern`)
- Hot code upgrades
- Web IDE (trace viewer)
- Language Server Protocol (LSP)
- Managed deployment platform
