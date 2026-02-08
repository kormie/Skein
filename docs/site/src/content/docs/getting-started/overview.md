---
title: Overview
description: What Skein is, what it can do today, and where it's headed.
---

## What is Skein?

Skein is a new programming language that compiles to BEAM bytecode and runs on the Erlang VM. The compiler and toolchain are implemented in Elixir as an umbrella project.

Skein is designed around six ranked principles:

| Priority | Principle | Summary |
|----------|-----------|---------|
| P1 | One Obvious Way | One idiomatic way to express each task -- no synonyms, no sugar |
| P2 | Spec Fits in Context | The complete language spec fits in 128K tokens (an LLM context window) |
| P3 | Types Are Contracts | Types serve the compiler, generate schemas, and constrain agent code |
| P4 | Effects Are Visible | Every side effect is declared, traced, and replayable |
| P5 | Crash Gracefully | OTP's "let it crash" philosophy is the default for agent workloads |
| P6 | Humans Read, Agents Write | Syntax favors regularity and unambiguous parsing over cleverness |

## What Works Today (Phases 1-5)

The compilation pipeline is operational through Phase 5. You can write `.skein` files with modules, functions, types, handlers, and store operations -- compile them to BEAM bytecode, and run them.

**Language constructs:**

- `module Name { ... }` -- module declarations
- `fn name(arg: Type) -> ReturnType { ... }` -- function declarations
- `let x = expr` -- immutable bindings
- `match expr { pattern -> expr }` -- pattern matching (the only conditional)
- `expr |> fn(args)` -- pipe operator
- `"string ${interpolation}"` -- string interpolation
- `type Name { fields }` -- record type declarations
- `enum Name { variants }` -- enum type declarations with transitions
- `capability namespace.kind(params)` -- capability declarations
- `handler http METHOD "/path" (req) -> { ... }` -- HTTP handler declarations
- All arithmetic operators: `+`, `-`, `*`, `/`
- All comparison operators: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical operators: `&&`, `||`
- Unary operators: `!` (prefix not), `!` and `?` (postfix)
- Function calls: `f(x, y)`
- Field access: `x.field`
- Function references: `&function_name`

**Type system:**

- Built-in types: `String`, `Int`, `Float`, `Bool`, `Uuid`, `Instant`, `Duration`, `Email`, `Url`
- Parameterized types: `Option[T]`, `Result[T, E]`, `List[T]`, `Map[K, V]`, `Set[T]`
- Type checking at function boundaries and operator validation
- JSON schema derivation from type declarations
- Constraint annotations: `@min`, `@max`, `@one_of`, `@default`

**Capabilities and effects:**

- Compile-time capability checking (missing capability = structured error with `fix_code`)
- HTTP effect calls: `http.get`, `http.post`, `http.put`, `http.patch`, `http.delete`
- Store effect calls: `store.<table>.get`, `store.<table>.put`, `store.<table>.delete`, `store.<table>.query`
- Runtime capability enforcement (second layer of defense)
- Automatic trace recording for every effect call

**Runtime:**

- HTTP client with capability enforcement and tracing
- Handler dispatch with route matching and path parameters
- ETS-backed store with capability-gated CRUD operations
- Lightweight HTTP server for serving handlers
- Trace recording with timing and outcome metadata

## What's Not Built Yet

- Agents (state machines, LLM calls, tool calling) -- Phase 6
- Built-in test constructs (`test`, `scenario`, `golden`) -- Phase 7
- CLI tooling (`skein new`, `skein build`, `skein test`) -- Phase 7
- `!` and `?` operators for Result unwrap/propagation -- parsed but not compiled
- Enum variant matching in codegen
- Managed storage backends (Postgres, SQLite) -- currently ETS only

See the [Roadmap](/Skein/roadmap/phase-2/) for the full plan.

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Compiler language | Elixir | Team familiarity, excellent BEAM tooling |
| Lexer | Hand-written (NimbleParsec-based) | Fast, composable token parsing |
| Parser | Hand-written recursive descent | Better error messages than parser generators |
| IR target | Core Erlang | Standard BEAM compilation target (used by Elixir, Gleam, LFE) |
| Testing | ExUnit + StreamData + PropCheck | Unit + property-based + stateful testing |
