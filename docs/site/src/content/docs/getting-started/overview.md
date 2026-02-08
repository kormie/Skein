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

## What Works Today (Phases 1-8e)

The compilation pipeline is operational through Phase 8e. You can write `.skein` files with modules, functions, types, HTTP/queue/schedule handlers, store operations, and agents -- compile them to BEAM bytecode, and run them on a Bandit + Plug HTTP server. The CLI tooling provides project scaffolding, building, testing, running, and trace inspection. Test constructs include `test`, `scenario` (with `given`/`expect`), and `golden` trace tests with a deterministic replay engine.

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
- `handler queue "queue-name" (msg) -> { ... }` -- queue handler declarations
- `handler schedule "cron-expr" () -> { ... }` -- schedule handler declarations
- `test "description" { ... }` -- inline test declarations
- `scenario "description" { given { ... } expect { ... } }` -- scenario tests
- `golden "description" from trace "file" { ... }` -- golden trace tests
- `agent Name { ... }` -- agent state machines with phases and handlers
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
- Memory effect calls: `memory.put`, `memory.get`, `memory.delete`, `memory.list`
- LLM effect calls: `llm.chat`, `llm.json`, `llm.stream`
- Runtime capability enforcement (second layer of defense)
- Automatic trace recording for every effect call

**Agents:**

- `agent` declarations with `Phase` enums and `->` transitions
- `on start(params)` and `on phase(Phase)` handlers
- Compile-time phase transition validation
- `transition(Phase)`, `stop()`, `emit(event)`, `state.field` access
- GenStateMachine-based runtime with automatic phase handler dispatch

**Runtime:**

- HTTP client with capability enforcement and tracing
- Handler dispatch with route matching and path parameters
- Queue dispatch with subscribe/publish for event-driven handlers
- Schedule dispatch with cron expression parsing for time-triggered handlers
- ETS-backed store with capability-gated CRUD operations
- Scoped KV memory with namespace isolation and capability enforcement
- LLM client with pluggable backends and schema-constrained JSON responses
- Agent runtime wrapping `:gen_statem` for phase-based state machines
- Bandit + Plug HTTP server with `req.json[T]` body validation
- Trace recording with timing and outcome metadata
- Replay engine for deterministic trace playback in tests

**CLI tooling:**

- `skein new <dir>` -- scaffold a new project with `skein.toml`, `src/`, `test/`, and example files
- `skein build <dir>` -- compile all `.skein` files in a project's `src/` tree
- `skein test <dir>` -- discover and run all tests across `src/` and `test/` directories
- `skein run <dir>` -- compile and start an HTTP server for handler modules
- `skein trace` -- view recent trace spans with `--last` and `--kind` filters

## What's Not Built Yet

- Managed storage backends (Postgres, SQLite via Ecto) -- currently ETS only
- Agent pool supervision (`AgentPool` with max concurrency)
- `suspend()` / `resume()` agent lifecycle
- Tool policies (rate limits, approval workflows)

See the [Roadmap](/Skein/roadmap/phase-2/) for the full plan.

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Compiler language | Elixir | Team familiarity, excellent BEAM tooling |
| Lexer | Hand-written (NimbleParsec-based) | Fast, composable token parsing |
| Parser | Hand-written recursive descent | Better error messages than parser generators |
| IR target | Core Erlang | Standard BEAM compilation target (used by Elixir, Gleam, LFE) |
| Testing | ExUnit + StreamData + PropCheck | Unit + property-based + stateful testing |
