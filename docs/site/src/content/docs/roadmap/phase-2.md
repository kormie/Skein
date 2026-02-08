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
| 4 | Handlers and HTTP Server | Next | HTTP handlers, routing, web server |
| 5 | Storage | Planned | `store.table` with typed records and migrations |
| 6 | Agents | Planned | State machines, LLM calls, tool calling |
| 7 | Testing, Replay, and CLI | Planned | Built-in tests, trace replay, `skein` CLI |

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

**Test counts:** 39 properties, 255 tests across compiler and runtime

## Phase 4: Handlers and HTTP Server (Next)

**Goal:** HTTP handlers with routing, request/response handling, and a running web server.

**Planned scope:**
- `handler http GET "/users/:id" (req) -> { ... }` syntax
- Route compilation: Skein routes to Plug router
- Request object: `req.params`, `req.json[T]`, `req.headers`
- Response helpers: `respond.json(status, body)`
- Handler-level tracing: every request produces a trace
- Bandit + Plug for the HTTP server

## Phase 5-7 (Future)

### Phase 5: Storage
`store.table` operations. Type-to-Ecto schema generation. Migration generation.

### Phase 6: Agents
The crown jewel -- state machine agents with phases, transitions, memory, LLM calls, and tool calling. Compiles to `gen_statem`.

### Phase 7: Testing, Replay, and CLI
Built-in `test` and `scenario` constructs. Deterministic trace replay. `skein new/build/test/run` CLI.

## Post-MVP Backlog

- Queue/topic handlers
- Schedule handlers
- LLM streaming
- Erlang/Elixir FFI (`extern`)
- Hot code upgrades
- Web IDE (trace viewer)
- Language Server Protocol (LSP)
- Managed deployment platform
