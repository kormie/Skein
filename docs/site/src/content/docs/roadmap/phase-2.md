---
title: Roadmap
description: What's been built, what's next, and the full 7-phase implementation plan.
---

## Phase Status

| Phase | Name | Status | Summary |
|-------|------|--------|---------|
| 1 | Hello BEAM | **Complete** | End-to-end compilation pipeline |
| 2 | Type System Foundation | Next | Type checking, `Option[T]`, `Result[T, E]`, schemas |
| 3 | Capabilities and Effects | Planned | Capability declarations and enforcement |
| 4 | Handlers and HTTP Server | Planned | HTTP handlers, routing, web server |
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

## Phase 2: Type System Foundation (Next)

**Goal:** Named types, enums, type checking at function boundaries, and JSON schema derivation.

**Planned scope:**

### Type Declarations
```
type User {
  id: Uuid
  email: String
  name: String
}
```
Record types compile to Erlang maps. The parser already handles these -- the code generator and analyzer need to be extended.

### Enum Declarations
```
enum Status {
  Active
  Suspended(reason: String)
  Deleted
}
```
Enum variants compile to tagged tuples. Variants with data carry the data in the tuple.

### Type Checking
- Verify function arguments match declared parameter types
- Verify return expressions match declared return types
- Infer types for `let` bindings from initializer expressions
- Check `match` arm patterns against the subject type
- Check `match` exhaustiveness (all enum variants covered)

### `Option[T]` and `Result[T, E]`
Built-in parameterized types:
- `Option[T]` = `Some(value)` or `None`
- `Result[T, E]` = `Ok(value)` or `Err(error)`

### Error Operators
- `!` (postfix): Unwrap a `Result`, crash on `Err`
- `?` (postfix): Propagate `Err`, early return from enclosing function

### Schema Derivation
Every named type automatically generates a JSON Schema:
```
type Money {
  amount: Int @min(0)
  currency: String @one_of(["USD", "CAD", "EUR"])
}
```
Produces:
```json
{
  "type": "object",
  "required": ["amount", "currency"],
  "properties": {
    "amount": {"type": "integer", "minimum": 0},
    "currency": {"type": "string", "enum": ["USD", "CAD", "EUR"]}
  }
}
```

### Constraint Annotations
- `@min(value)` -- minimum value for numeric fields
- `@max(value)` -- maximum value for numeric fields
- `@one_of([values])` -- enumerated string values
- `@default(value)` -- default value for optional fields

## Phase 3-7 (Future)

### Phase 3: Capabilities and Effects
Compile-time and runtime capability enforcement. First real effects (`http.get`, `http.post`). Trace scaffolding.

### Phase 4: Handlers and HTTP Server
HTTP handlers with routing. Request/response handling. Bandit + Plug web server.

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
