# Skein Implementation Plan

## Overview

This plan breaks Skein development into 7 phases, each producing a working, testable artifact. Phases are ordered by dependency — each phase builds on the previous one. Each phase has clear acceptance criteria so you know when it's done.

**Estimated total effort:** 12-16 weeks for a single developer (or pair of developer + Claude Code sessions).

---

## Phase 1: Hello BEAM (Weeks 1-2)

**Goal:** Prove the end-to-end compilation pipeline works. Lex, parse, analyze, generate Core Erlang, compile to BEAM, and call the resulting function.

### Scope

- Lexer: tokens for `module`, `fn`, `let`, `match`, basic types, literals, operators, braces, parens, commas, pipes, `--` comments
- Parser: `module`, `fn`, `let` bindings, string interpolation, `match` expressions, function calls, pipe operator
- AST: node types for the above with source location metadata
- Code generator: AST → Core Erlang (using `:cerl` module) → `.beam` bytecode
- Structured errors: at least `UnexpectedToken`, `UnknownIdentifier` with JSON serialization

### Constructs Supported

```
module Name {
  fn name(arg: Type) -> ReturnType {
    let x = expr
    match expr {
      pattern -> expr
    }
    expr |> fn(args)
    "string ${interpolation}"
  }
}
```

### Types Supported (Phase 1)

`String`, `Int`, `Float`, `Bool` — enough for hello world programs. No `Option`, `Result`, `List`, `Map` yet.

### Acceptance Criteria

```
-- hello.skein
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }

  fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn classify(n: Int) -> String {
    match n > 0 {
      true  -> "positive"
      false -> "non-positive"
    }
  }
}
```

All three functions compile to BEAM and return correct results when called from Elixir tests.

Compiler errors produce JSON output with `code`, `message`, `location`, `fix_hint`.

### Key Decisions to Make

- [x] Exact token representation: `{:keyword, {line, col}}` tuples
- [x] Core Erlang variable naming: snake_case to CamelCase conversion
- [x] String interpolation: compile to `erlang:iolist_to_binary/1` over iolist

---

## Phase 2: Type System Foundation (Weeks 3-4)

**Goal:** Named types, enums, type checking at function boundaries, and JSON schema derivation.

### Scope

- `type` declarations (record types with typed fields)
- `enum` declarations (algebraic data types with variant data)
- Type checker: verify function argument/return types, match exhaustiveness
- `Option[T]` and `Result[T, E]` as built-in parameterized types
- `!` operator (unwrap Result, crash on Err)
- `?` operator (propagate Err, early return)
- Schema derivation: type definition → JSON Schema output
- `@min`, `@max`, `@one_of`, `@default` constraint annotations

### Constructs Added

```
type User {
  id: Uuid
  email: String
  name: String
}

enum Status {
  Active
  Suspended(reason: String)
  Deleted
}

fn get_user(id: Uuid) -> Result[User, DbError] { ... }

let user = get_user(id)!        -- crash on error
let user = get_user(id)?        -- propagate error

type Money {
  amount: Int @min(0)
  currency: String @one_of(["USD", "CAD", "EUR"])
}
```

### Acceptance Criteria

- Type-incorrect programs produce clear errors: "Expected String, got Int at line 12, col 5"
- Non-exhaustive match expressions produce warnings with missing patterns listed
- `User` type generates correct JSON Schema via `Skein.SchemaGen.to_json_schema(User)`
- `Result` unwrap (`!`) compiles to a pattern match that calls `:erlang.error/1` on the Err branch
- Constraint annotations appear in generated JSON Schema (`minimum`, `enum`, `default`)

---

## Phase 3: Capabilities and Effects (Weeks 5-6)

**Goal:** Capability declarations, compile-time capability checking, and the first effectful operations (HTTP client, console output for debugging).

### Scope

- `capability` declarations at module level
- Capability checker in the analyzer: verify every effect call has a covering capability
- Runtime capability enforcement (second layer)
- `http.get`, `http.post` as the first real effects (backed by Req in the runtime)
- Trace scaffolding: every effect call captures timing, metadata, and outcome
- Structured capability errors: "Capability 'http.out' required but not declared" with `fix_code`

### Constructs Added

```
module MyService {
  capability http.out("api.example.com")

  fn fetch_data(id: String) -> Result[Data, HttpError] {
    http.get("https://api.example.com/data/${id}")
  }
}
```

### Acceptance Criteria

- A module that calls `http.get` without declaring `capability http.out(...)` fails to compile
- The error includes `fix_code: "capability http.out(\"api.example.com\")"`
- A module with correct capabilities compiles and the HTTP call executes at runtime
- The runtime blocks HTTP calls to undeclared hosts even if the compiler is bypassed
- Each HTTP call produces a trace span with timing and status code

---

## Phase 4: Handlers and HTTP Server (Complete)

**Goal:** HTTP handlers with routing, request/response handling, and a running web server. This is the first time Skein can serve traffic.

### Scope

- `handler http METHOD "/path/:param" (req) -> { ... }` syntax
- Route compilation: Skein routes → Plug router
- Request object: `req.params`, `req.json[T]`, `req.headers`
- Response helpers: `respond.json(status, body)`
- `idempotent(key)` for deduplication
- Handler-level tracing: every request produces a trace with timing, status, route

### Constructs Added

```
module UserService {
  capability http.in
  capability store.table("users")

  type User {
    id: Uuid
    email: String
    name: String
  }

  handler http GET "/users/:id" (req) -> {
    let id = Uuid.parse!(req.params.id)
    let user = User.get!(id)
    respond.json(200, user)
  }

  handler http POST "/users" (req) -> {
    let input = req.json[User]?
    let user = User.create!(input)
    respond.json(201, user)
  }
}
```

### Acceptance Criteria

- `skein build` compiles a service with HTTP handlers into a runnable OTP application
- `skein run` starts the HTTP server on a configurable port
- GET and POST handlers respond correctly with JSON bodies
- Route params are extracted and available as `req.params`
- Request body is parsed and validated against the declared type
- Invalid JSON body returns 400 with structured error response
- Each request produces a trace viewable via a debug endpoint (`GET /__skein/traces`)

---

## Phase 5: Storage (Complete)

**Goal:** `store.table` with typed records, basic queries, and schema migrations.

### Scope

- `store.table` capability and operations: `get`, `put`, `query`, `delete`
- Type → Ecto schema generation (compile-time)
- Migration generation when types change
- `@primary` and `@unique` annotations on type fields
- Local dev backed by SQLite; production path uses Postgres

### Constructs Added

```
module UserService {
  capability store.table("users")

  type User {
    id: Uuid @primary
    email: String @unique
    name: String
    created_at: Instant
  }

  fn find_by_email(email: String) -> Result[User, NotFound] {
    store.users.query(email: email) |> List.first_or(NotFound)
  }
}
```

### Acceptance Criteria

- Types with `@primary` generate corresponding Ecto schemas and migrations
- `store.users.get(id)` compiles to an Ecto query
- `store.users.put(record)` compiles to an Ecto insert/upsert
- Schema changes between compiles generate migration files
- All store operations produce trace spans

---

## Phase 6: Agents (Weeks 10-12)

**Goal:** The agent construct — state machines with phases, transitions, memory, LLM calls, and tool calling. This is the crown jewel.

### Scope

- `agent` declaration with `state`, `Phase` enum with transitions, `on start`, `on phase(...)` handlers
- Agent → `gen_statem` compilation
- `transition(Phase)` with compile-time transition validation
- `suspend()` / `resume()` lifecycle
- `memory.put` / `memory.get` with automatic instance scoping
- `llm.json[T]` and `llm.chat` — LLM client with schema-constrained decoding
- `tool` declarations with contract/implementation separation
- `tool.call` — tool execution with tracing
- Agent pool supervision (`AgentPool` with max concurrency)
- `emit` for domain events

### Sub-phases

**6a: Agent skeleton (week 10)**
- Agent compiles to gen_statem
- Phase enum with transition validation
- `on start` and `on phase(...)` dispatch
- `transition()` and `stop()`

**6b: Memory and LLM (week 11)**
- Scoped memory (KV store per agent instance)
- `llm.json[T]` with schema generation and response validation
- `llm.chat` for unstructured responses
- `LlmError` enum with retry-relevant variants

**6c: Tools and events (week 12)**
- `tool` declarations with input/output/implement blocks
- `tool.call` execution with tracing
- Tool schema auto-generation (for LLM function calling manifests)
- `emit` domain events
- Tool policies (rate limits, approval requirements)

### Acceptance Criteria

```
-- The RefundAgent from the spec compiles and runs:
-- 1. Starts in Analyze phase
-- 2. Calls llm.json to decide eligibility
-- 3. Transitions to Refund or Done based on decision
-- 4. Calls Stripe.CreateRefund tool
-- 5. Emits RefundIssued event
-- 6. Reaches Done phase

-- Invalid transitions (e.g., Done -> Analyze) fail at compile time.
-- Agent crash triggers supervisor restart from last checkpoint.
-- All phases, LLM calls, and tool calls produce trace spans.
```

---

## Phase 7: Testing, Replay, and CLI (Weeks 13-14)

**Goal:** Built-in test constructs, deterministic replay, golden trace tests, and a polished CLI.

### Scope

- `test "description" { ... }` construct
- `scenario` tests with `given`/`expect` blocks
- `golden` trace tests with `replay`
- Replay engine: re-execute handlers/agents against recorded I/O
- `skein new` — project scaffolding
- `skein build` — compile to OTP release
- `skein test` — run all test types
- `skein run` — start the service locally
- `skein trace` — view recent traces (CLI table output)

### Acceptance Criteria

- `test` blocks compile and run via `skein test`
- Scenario tests validate agent behavior against declared expectations
- Golden tests replay a recorded trace and assert identical outcomes
- `skein new myservice` generates a working project with example handler and agent
- `skein build` produces a runnable OTP release
- `skein trace --last 10` shows recent traces with timing and outcomes

---

## Phase 8: Hardening and Infrastructure (Next Priorities)

These are the immediate next priorities after Phase 7. They fill gaps in the existing implementation and make Skein usable for real projects.

### 8a: Test Infrastructure — `scenario`, `golden`, `replay` ✅

**Goal:** Complete the built-in test constructs so agents can be tested deterministically.

- [x] `scenario` tests with `given`/`expect` blocks — compile and execute with variable bindings
- [x] `golden` trace tests — load trace file, run assertions against recorded data
- [x] `replay` engine (`Skein.Runtime.Replay`) — load and replay recorded I/O spans deterministically
- [x] Integrate with `skein test` CLI command — `kind` field tracks test/scenario/golden types

**Acceptance criteria:** A scenario test for an agent compiles, replays a recorded LLM response, and asserts the agent transitions through expected phases. ✅

**Implementation notes:**
- Parser: `parse_scenario_decl` handles `scenario "desc" { given { k: v } expect { assertions } }`
- Parser: `parse_golden_decl` handles `golden "desc" from trace "file" { assertions }`
- AST: New `Scenario` (description, given_vars, expect_body) and `Golden` (description, trace_file, body) nodes
- CodeGen: Scenario tests compile to `__test_N__/0` with `let` bindings from given vars before expect body
- CodeGen: Golden tests compile to `__test_N__/0` that calls `Skein.Runtime.Replay.load_trace/1` then runs body
- `__tests__/0` metadata includes `:kind` field (`:test`, `:scenario`, or `:golden`)
- CLI test runner propagates `kind` through results for reporting
- Replay module supports handler, llm, memory, http, and unknown span types
- 7 new parser property tests, 11 new parser unit tests, 11 new integration tests, 13 replay tests, 3 CLI tests

### 8b: Storage Backend — Ecto Integration

**Goal:** Connect the abstract `store.*` operations to a real database.

- [ ] Ecto schema generation from Skein `type` declarations with `@primary`/`@unique`
- [ ] Migration generation when types change between compiles
- [ ] SQLite backend for local dev, Postgres for production
- [ ] Wire `store.get`, `store.put`, `store.query`, `store.delete` to Ecto queries at runtime

**Acceptance criteria:** A Skein module with `capability store.table("users")` compiles and performs real CRUD against SQLite in tests.

### 8c: HTTP Server — Bandit + Plug Integration ✅

**Goal:** Replace the dev-only `:gen_tcp` server with production-grade HTTP.

- [x] Compile Skein handlers to a Plug router (`Skein.Runtime.Router`)
- [x] Use Bandit as the HTTP server
- [x] Preserve `/__skein/traces` debug endpoint
- [x] Support request body validation via `req.json[T]` (`Skein.Runtime.Request`)

**Acceptance criteria:** `skein run` starts a Bandit server that passes all existing handler tests and handles concurrent requests correctly. ✅

**Implementation notes:**
- `Skein.Runtime.Router` dynamically builds Plug modules from compiled handler metadata
- `Skein.Runtime.Request.json/2` parses JSON bodies and validates against compile-time schemas
- Parser updated to create `Call` AST nodes for type-parameterized expressions without call args (e.g., `req.json[T]`)
- Router catches handler exceptions and returns 500 for graceful error handling
- 42 new tests (11 router, 9 Bandit server, 12 request unit, 6 request properties, 4 integration)

### 8d: Canonical Examples ✅

**Goal:** Provide working examples that demonstrate the full language.

- [x] `examples/hello_http.skein` — HTTP handler with multiple endpoints and route parameters
- [x] `examples/refund_agent.skein` — Agent with phases, LLM, memory, and events
- [x] `examples/incident_triage.skein` — Multi-phase agent with classification and escalation
- [x] `examples/queue_worker.skein` — Mixed handler types (HTTP, queue, schedule)
- [x] All examples compile and have corresponding integration tests (21 tests)

**Acceptance criteria:** All examples compile successfully. Each has integration tests exercising handler functions, metadata, and module attributes.

### 8e: Queue and Schedule Handlers ✅

**Goal:** Support event-driven and time-triggered handlers beyond HTTP.

- [x] `handler queue "queue-name" (msg) -> { ... }` — subscribe to a message queue
- [x] `handler schedule "*/5 * * * *" () -> { ... }` — cron-style scheduled execution
- [x] Parser branches on handler source (`http`, `queue`, `schedule`) with appropriate syntax
- [x] Analyzer validates `queue.in` and `schedule.in` capabilities (E0030)
- [x] CodeGen emits `source` field in `__handlers__/0` metadata, handles nil method/param
- [x] `Skein.Runtime.Queue` — GenServer-based message queue dispatch with subscribe/publish
- [x] `Skein.Runtime.Schedule` — Cron-based scheduling with register/trigger and expression parsing
- [x] 24 new unit tests + 2 property tests across all pipeline stages

**Acceptance criteria:** A queue handler compiles and processes messages from an in-memory queue. A schedule handler compiles and can be triggered by the test harness. Mixed handler modules (HTTP + queue + schedule) work correctly.

### 8f: LLM Streaming

**Goal:** Support streaming LLM responses for real-time agent output.

- [ ] `llm.stream` API with `on_chunk` callback
- [ ] Token-level streaming in the runtime LLM client
- [ ] Trace spans for streaming calls (total duration, chunk count)
- [ ] Capability checking for `llm.stream` (same as `llm.chat`)

**Acceptance criteria:** An agent calls `llm.stream` and processes chunks via callback. The full response is assembled and a trace span records the streaming call.

---

## Post-MVP Backlog (Not Prioritized)

These are features that matter but are explicitly out of scope for the initial build:

- [ ] `extern` FFI for Erlang/Elixir interop
- [ ] Hot code upgrades
- [ ] Multi-region clustering
- [ ] Web IDE (trace viewer, live editing)
- [ ] Language Server Protocol (LSP) for editor integration
- [ ] `llm.embed` and `llm.rerank` for RAG pipelines
- [ ] Human-in-the-loop approval workflows
- [ ] Managed deployment platform
- [ ] Marketplace for curated tools/connectors
- [ ] Formal grammar specification (BNF)
- [ ] Gradual typing exploration
- [ ] Performance optimization (compiler speed, generated code efficiency)

---

## Risk Log

| Risk | Mitigation |
|------|-----------|
| Core Erlang generation is fiddly | Start with simplest possible output; use `:cerl` module helpers; study how Elixir does it in `elixir_erl.erl` |
| Type inference is a rabbit hole | Start with explicit types at all boundaries; add local inference incrementally |
| gen_statem is complex | Build a thin Skein.Agent behaviour on top that handles the boilerplate |
| LLM provider APIs change frequently | Abstract behind a provider-agnostic `Skein.LLM.Client` behaviour; start with one provider |
| Scope creep from "just one more feature" | Enforce the 128K token spec budget as a hard constraint |
| String interpolation in Core Erlang is non-trivial | Compile to binary construction (`<<>>`) at the Core Erlang level |
