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

## What Works Today (Phase 1)

The end-to-end compilation pipeline is operational. You can write a `.skein` file, compile it to BEAM bytecode, and call the resulting module's functions from Elixir.

**Supported constructs:**

- `module Name { ... }` -- module declarations
- `fn name(arg: Type) -> ReturnType { ... }` -- function declarations
- `let x = expr` -- immutable bindings
- `match expr { pattern -> expr }` -- pattern matching (the only conditional)
- `expr |> fn(args)` -- pipe operator
- `"string ${interpolation}"` -- string interpolation
- All arithmetic operators: `+`, `-`, `*`, `/`
- All comparison operators: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical operators: `&&`, `||`
- Unary operators: `!` (prefix not), `!` and `?` (postfix)
- Function calls: `f(x, y)`
- Field access: `x.field`
- Function references: `&function_name`

**Supported types (Phase 1):**

`String`, `Int`, `Float`, `Bool` -- enough for hello-world programs. `Option`, `Result`, `List`, `Map` are coming in Phase 2.

## What's Not Built Yet

- Type checking (the analyzer is a pass-through stub)
- `type` and `enum` declarations (parsed but not compiled)
- Capability system (parsed but not enforced)
- Handlers, agents, tools, supervisors (future phases)
- Runtime library (agents, HTTP, storage, LLM, tracing)
- CLI tooling (`skein new`, `skein build`, `skein test`)

See the [Roadmap](/Skein/roadmap/phase-2/) for the full plan.

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Compiler language | Elixir | Team familiarity, excellent BEAM tooling |
| Lexer | Hand-written (NimbleParsec-based) | Fast, composable token parsing |
| Parser | Hand-written recursive descent | Better error messages than parser generators |
| IR target | Core Erlang | Standard BEAM compilation target (used by Elixir, Gleam, LFE) |
| Testing | ExUnit + StreamData + PropCheck | Unit + property-based + stateful testing |
