---
title: Overview
description: What Skein is, what it can do today, and where it's headed.
---

## What is Skein?

Skein is a new programming language that compiles to BEAM bytecode and runs on the Erlang VM. It ships as a standalone binary for Linux and macOS — no Erlang or Elixir install required. Install it with one command — `curl -fsSL https://kormie.github.io/Skein/install.sh | sh` — or grab a binary from the [Releases page](https://github.com/kormie/Skein/releases), and you're ready to go. See the [Quickstart](/Skein/getting-started/quickstart/) to get running in under 5 minutes.

Skein is designed around six ranked principles:

| Priority | Principle | Summary |
|----------|-----------|---------|
| P1 | One Obvious Way | One idiomatic way to express each task -- no synonyms, no sugar |
| P2 | Spec Fits in Context | The complete language spec fits in 128K tokens (an LLM context window) |
| P3 | Types Are Contracts | Types serve the compiler, generate schemas, and constrain agent code |
| P4 | Effects Are Visible | Every side effect is declared, traced, and replayable |
| P5 | Crash Gracefully | OTP's "let it crash" philosophy is the default for agent workloads |
| P6 | Humans Read, Agents Write | Syntax favors regularity and unambiguous parsing over cleverness |

## What Works Today

The compilation pipeline is fully operational. You can write `.skein` files with modules, functions, types, tools, supervisors, HTTP/queue/schedule handlers, store operations, and agents — compile them to BEAM bytecode, and run them on a Bandit + Plug HTTP server. Store tables are typed — `capability store.table("users", User)` names the record type, operations are type-checked at compile time, and writes are schema-checked at runtime — backed by the in-memory ETS runtime store. The CLI tooling provides project scaffolding, building, testing, running, and trace inspection. Test constructs include `test`, `scenario` (with `given`/`expect`), and `golden` trace tests with a deterministic replay engine.

**Language constructs:**

- `module Name { ... }` -- module declarations
- `fn name(arg: Type) -> ReturnType { ... }` -- function declarations
- `let x = expr` -- immutable bindings
- `match expr { pattern -> expr }` -- pattern matching (the only conditional)
- `expr |> fn(args)` -- pipe operator
- `"string ${interpolation}"` -- string interpolation
- `type Name { fields }` -- record type declarations
- `enum Name { variants }` -- enum type declarations with transitions
- `capability namespace.kind(params)` / `capability model(provider, model)` -- capability declarations
- `handler http METHOD "/path" (req) -> { ... }` -- HTTP handler declarations
- `handler queue "queue-name" (msg) -> { ... }` -- queue handler declarations
- `handler schedule "cron-expr" () -> { ... }` -- schedule handler declarations
- `test "description" { ... }` -- inline test declarations
- `scenario "description" { given { ... } expect { ... } }` -- scenario tests
- `golden "description" from trace "file" { ... }` -- golden trace tests
- `agent Name { ... }` -- agent state machines with phases and handlers
- `tool Name.Action { ... }` -- typed tool declarations with `input`/`output` schemas, the cross-module call seam
- `supervisor Name { ... }` -- supervision trees with `child` entries, restart policies, strategy, and `max_restarts`
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
- Type inference — field access resolves types through record definitions
- JSON schema derivation from type declarations
- Constraint annotations: `@min`, `@max`, `@one_of`, `@default`, `@primary`, `@unique`, `@description`

**Capabilities and effects:**

- Compile-time capability checking (missing capability = structured error with `fix_code`)
- HTTP effect calls: `http.get`, `http.post`, `http.put`, `http.patch`, `http.delete`
- Store effect calls: `store.<table>.get`, `store.<table>.put`, `store.<table>.delete`, `store.<table>.query`
- Memory effect calls: `memory.put`, `memory.get`, `memory.delete`, `memory.list`
- LLM effect calls: `llm.chat`, `llm.json`, `llm.stream`, `llm.embed`
- Runtime capability enforcement across all subsystems (HTTP, store, memory, LLM)
- Automatic trace recording for every effect call with timing, outcome, and token usage

**Agents:**

- `agent` declarations with `Phase` enums and `->` transitions
- `on start(params)` and `on phase(Phase)` handlers
- Compile-time phase transition validation
- `transition(Phase)`, `stop()`, `suspend(reason)`, `emit(event)`, `state.field` access
- `suspend(reason)` for human-in-the-loop workflows — the host resumes a suspended agent from outside via `Skein.Runtime.Agent.resume(pid, phase)`
- `gen_statem`-based runtime with automatic phase handler dispatch

**Runtime:**

- HTTP client with capability enforcement and tracing
- Handler dispatch with route matching and path parameters
- Queue dispatch with subscribe/publish for event-driven handlers
- Schedule dispatch with cron expression parsing for time-triggered handlers
- ETS-backed store with capability-gated CRUD operations and schema-checked typed-table writes
- Scoped KV memory with namespace isolation and capability enforcement
- LLM client with pluggable backends — Anthropic (production default), OpenAI-compatible (local model servers + embeddings), and AWS Bedrock — and schema-validated JSON responses
- Agent runtime wrapping `:gen_statem` for phase-based state machines
- Real OTP supervision from `supervisor` declarations — `skein run` boots them via `Skein.Runtime.SupervisorHost` with restart policies and `max_restarts` intensity
- Opt-in SQLite persistence for the event log — `skein run` writes events to `.skein/events.db` by default (`--no-persist` opts out) and reloads history on restart
- Bandit + Plug HTTP server with `req.json[T]` body validation
- Trace recording with timing, outcome, and token usage metadata
- Trace enrichment with model-specific usage data (input/output tokens, cost)
- Replay engine for deterministic trace playback in tests

**CLI tooling:**

- `skein new <dir>` -- scaffold a new project with `skein.toml`, `src/`, `test/`, `AGENTS.md`, `CLAUDE.md`, `README.md`, and `.gitignore` (git-inits by default)
- `skein compile <file.skein>` -- compile a single `.skein` file
- `skein build [dir]` -- compile all `.skein` files in a project's `src/` tree
- `skein test [dir]` -- discover and run all tests across `src/` and `test/` directories
- `skein run [dir]` -- compile and start an HTTP server for handler modules
- `skein trace` -- view recent trace spans with `--last` and `--kind` filters
- `skein agents [dir]` -- create or refresh `AGENTS.md` in an existing project
- `skein mcp` -- MCP server over stdio, so coding agents can compile, test, and trace Skein projects
- `skein lsp` -- language server over stdio, for editor integrations
- `skein completions zsh` -- print the zsh shell completion script
- `skein version` / `skein help` -- version and usage info

**Editor tooling:**

- VS Code extension with syntax highlighting, 30+ snippets, and full LSP integration
- Language Server Protocol (LSP) providing diagnostics, document symbols, hover, go-to-definition, code completion, and semantic tokens
- LSP server built with [GenLSP](https://github.com/elixir-tools/gen_lsp), using the Skein compiler for analysis

See the [Editor Support](/Skein/editor/vscode/) docs for setup instructions.

## What's Not Built Yet

- Agent pool supervision (`AgentPool` with max concurrency)

Tool `policy` blocks (rate limits, approval workflows) were **cut from the language** (#319) — runtime policy enforcement is out of the language surface, not forthcoming.

See the [Roadmap](/Skein/roadmap/overview/) for the full plan.

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Compiler language | Elixir | Team familiarity, excellent BEAM tooling |
| Lexer | Hand-written (binary pattern matching) | Fast, dependency-free tokenizing with precise error positions |
| Parser | Hand-written recursive descent | Better error messages than parser generators |
| IR target | Core Erlang | Standard BEAM compilation target (used by Elixir, Gleam, LFE) |
| Language server | GenLSP | OTP behaviour for LSP implementations |
| Testing | ExUnit + StreamData + PropCheck | Unit + property-based + stateful testing |
