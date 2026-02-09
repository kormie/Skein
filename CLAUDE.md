# CLAUDE.md — Skein Language Project

## What Is This Project

Skein is a new programming language that compiles to BEAM bytecode and runs on the Erlang VM (OTP). It is designed for building cloud services where AI agents are first-class constructs. The language is co-optimized for humans to read and LLM agents to write.

The compiler and toolchain are implemented in Elixir. The runtime is a set of OTP behaviours and libraries that Skein programs link against.

## Project Structure

```
skein/
├── CLAUDE.md                    # This file
├── mix.exs                      # Root umbrella project
├── docs/
│   ├── SKEIN_SPEC.md            # Complete language specification
│   ├── ARCHITECTURE.md          # Compiler and runtime architecture
│   ├── IMPLEMENTATION_PLAN.md   # Phased build plan with acceptance criteria
│   └── site/                    # Astro + Starlight documentation site
├── apps/
│   ├── skein_compiler/          # Lexer, parser, analyzer, code generator
│   │   ├── lib/
│   │   │   ├── skein/
│   │   │   │   ├── lexer.ex         # Tokenizer (NimbleParsec-based)
│   │   │   │   ├── parser.ex        # AST construction
│   │   │   │   ├── ast.ex           # AST node type definitions
│   │   │   │   ├── analyzer.ex      # Type, capability, and transition checking
│   │   │   │   ├── codegen/
│   │   │   │   │   ├── core_erlang.ex   # AST -> Core Erlang
│   │   │   │   │   └── schema_gen.ex    # Type -> JSON Schema
│   │   │   │   └── error.ex         # Structured error types (JSON-emittable)
│   │   │   └── skein_compiler.ex
│   │   └── test/
│   ├── skein_runtime/           # OTP behaviours and runtime support
│   │   ├── lib/
│   │   │   ├── skein/
│   │   │   │   └── runtime/
│   │   │   │       ├── agent.ex         # Agent behaviour (gen_statem-based)
│   │   │   │       ├── handler.ex       # Handler dispatch
│   │   │   │       ├── tool.ex          # Tool registry and execution
│   │   │   │       ├── capability.ex    # Runtime capability enforcement
│   │   │   │       ├── memory.ex        # Scoped KV memory
│   │   │   │       ├── trace.ex         # Trace capture and storage
│   │   │   │       ├── llm.ex           # LLM client, JSON decoding, streaming
│   │   │   │       ├── store.ex         # Storage abstraction
│   │   │   │       ├── store_ecto.ex    # Ecto-backed storage implementation
│   │   │   │       ├── ecto_schema.ex   # Dynamic Ecto schema creation
│   │   │   │       ├── migration_gen.ex # Database migration generation
│   │   │   │       ├── repo.ex          # Ecto repository (SQLite3)
│   │   │   │       ├── http.ex          # HTTP support
│   │   │   │       ├── router.ex        # HTTP routing
│   │   │   │       ├── server.ex        # Server infrastructure
│   │   │   │       ├── request.ex       # HTTP request handling
│   │   │   │       ├── queue.ex         # Queue implementation
│   │   │   │       ├── schedule.ex      # Scheduling/timing
│   │   │   │       └── replay.ex        # Event replay
│   │   │   └── skein_runtime.ex
│   │   └── test/
│   ├── skein_cli/               # CLI tooling (skein new, build, test, deploy)
│   │   ├── lib/
│   │   │   ├── skein_cli.ex
│   │   │   └── skein/
│   │   │       └── cli/
│   │   │           └── main.ex
│   │   └── test/
│   └── skein_lsp/               # Language Server Protocol implementation
│       ├── lib/
│       └── test/
├── examples/                    # Canonical Skein programs
│   ├── hello.skein
│   ├── hello_http.skein
│   ├── refund_agent.skein
│   ├── incident_triage.skein
│   ├── queue_worker.skein
│   └── supervisor_pool.skein
└── .docs-config.json            # Documentation site configuration
```

## Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Compiler language | Elixir | Team familiarity, excellent BEAM tooling, Mix ecosystem |
| Lexer | NimbleParsec | Fast, composable, well-maintained PEG parser combinator |
| Parser | Hand-written recursive descent | More control over error messages than parser generators; better for structured error recovery |
| IR target | Core Erlang | Standard BEAM compilation target; used by Elixir, LFE, Gleam |
| Agent runtime | gen_statem (OTP built-in) | OTP's state machine behaviour; direct fit for Skein agents |
| HTTP server | Bandit + Plug | Modern, pure-Elixir HTTP; Plug for routing |
| Storage | Ecto + SQLite3 | Elixir data layer; SQLite via ecto_sqlite3 |
| Testing | ExUnit | Standard Elixir; extended with Skein-specific assertions |
| LSP | GenLSP | Language Server Protocol implementation |
| CLI | Optimus | Elixir CLI argument parser |

## Key Dependencies

```elixir
# skein_compiler/mix.exs
{:nimble_parsec, "~> 1.4"},
{:jason, "~> 1.4"},           # JSON for structured errors and schema gen
{:stream_data, "~> 1.1", only: [:test, :dev]},   # Property-based testing
{:propcheck, "~> 1.4", only: [:test, :dev]},      # Stateful property testing
{:libgraph, "~> 0.13", only: [:test, :dev]},      # Graph algorithms for testing

# skein_runtime/mix.exs
{:jason, "~> 1.4"},
{:bandit, "~> 1.6"},
{:plug, "~> 1.16"},
{:ecto, "~> 3.12"},
{:ecto_sql, "~> 3.12"},
{:ecto_sqlite3, "~> 0.17"},   # SQLite3 storage backend
{:exqlite, "~> 0.24"},
{:decimal, "~> 2.3"},
{:stream_data, "~> 1.1", only: [:test, :dev]},
{:propcheck, "~> 1.4", only: [:test, :dev]},
```

## Coding Conventions

### Elixir Style
- Follow standard Elixir formatting (`mix format`)
- Use typespecs (`@spec`) on all public functions
- Use `@moduledoc` and `@doc` on all public modules and functions
- Pattern match in function heads over case/cond where possible
- Prefer pipe operator for data transformations
- No abbreviations in variable/function names (except widely understood: `ctx`, `opts`, `acc`)

### AST Representation
- AST nodes are plain Elixir structs defined in `Skein.AST`
- Every AST node carries a `meta` field with source location: `%{line: int, col: int, file: string}`
- Node types match Skein constructs 1:1 (no "desugaring" in the parser; that happens in the analyzer)

```elixir
# Example AST nodes
defmodule Skein.AST do
  defmodule Module do
    defstruct [:name, :capabilities, :body, :meta]
  end

  defmodule Fn do
    defstruct [:name, :params, :return_type, :body, :meta]
  end

  defmodule Agent do
    defstruct [:name, :capabilities, :state_fields, :phases, :handlers, :meta]
  end

  defmodule Match do
    defstruct [:subject, :arms, :meta]
  end

  # ... etc
end
```

### Error Handling
- Compiler errors are structs that can serialize to JSON
- Every error has: `code`, `severity`, `message`, `location`, `fix_hint`, `fix_code`
- Never raise exceptions for user-facing errors; collect and return them
- Use `{:ok, result}` / `{:error, errors}` tuples throughout the compiler pipeline

```elixir
defmodule Skein.Error do
  defstruct [:code, :severity, :message, :location, :context, :fix_hint, :fix_code]

  @type t :: %__MODULE__{
    code: String.t(),
    severity: :error | :warning,
    message: String.t(),
    location: %{file: String.t(), line: pos_integer(), col: pos_integer()},
    context: String.t() | nil,
    fix_hint: String.t() | nil,
    fix_code: String.t() | nil
  }
end
```

### Testing Conventions

**TDD is mandatory.** Write tests before or alongside implementation — never after. Every public function must have tests covering its happy path and error cases before the implementation is considered done.

- Every compiler phase has its own test directory under `spec/`
- Spec tests use `.skein` source files as input and compare against expected output
- Use snapshot testing for AST and Core Erlang output (store expected output in `.expected` files)
- Runtime tests use ExUnit with Skein-specific helpers
- Integration tests compile `.skein` source to BEAM and call the resulting functions

**Property Testing** is required for components with wide input spaces:

| Library | Use Case | When to Use |
|---------|----------|-------------|
| `StreamData` | Standard property-based testing | Lexer (random valid/invalid source strings), parser (generated token streams), type checker (generated type combinations), codegen (generated ASTs) |
| `PropCheck` (PropEr) | Stateful/state-machine testing | Agent lifecycle (phase transitions), runtime behaviours (gen_statem sequences), store operations (sequential command sequences) |

- Use `StreamData` generators for all data-in/data-out functions (pure transforms)
- Use `PropCheck`'s `forall` and state machine testing for stateful components
- Property tests go alongside unit tests in the same test file
- Name property tests descriptively: `property "lexer round-trips all valid tokens"`

```elixir
# Example: property test for lexer
use ExUnitProperties

property "tokenizing any valid identifier produces an :ident token" do
  check all name <- identifier_generator() do
    assert {:ok, [{:ident, {1, 1}, ^name}, {:eof, _}]} = Skein.Lexer.tokenize(name)
  end
end
```

```elixir
# Example: unit test
defmodule Skein.LexerTest do
  use ExUnit.Case

  test "tokenizes a simple binding" do
    assert {:ok, tokens} = Skein.Lexer.tokenize("let x = 42")
    assert tokens == [
      {:let, {1, 1}},
      {:ident, {1, 5}, "x"},
      {:eq, {1, 7}},
      {:int, {1, 9}, 42}
    ]
  end
end
```

### Git Conventions
- Branch naming: `phase-N/description` (e.g., `phase-1/lexer-core-tokens`)
- Commit messages: `[phase-N] component: description`
- Each phase from the implementation plan is a PR

## Compilation Pipeline

```
Source (.skein)
    │
    ▼
┌─────────┐
│  Lexer   │  Source text -> Token stream
└────┬─────┘
     │
     ▼
┌─────────┐
│  Parser  │  Token stream -> AST
└────┬─────┘
     │
     ▼
┌──────────┐
│ Analyzer │  AST -> Annotated AST (types, capabilities, transitions validated)
└────┬─────┘
     │
     ▼
┌──────────┐
│ CodeGen  │  Annotated AST -> Core Erlang source
└────┬─────┘
     │
     ▼
┌───────────────┐
│ compile_module│  Core Erlang -> BEAM bytecode (.beam files)
│ (OTP built-in)│
└───────────────┘
```

## How Core Erlang Works

Core Erlang is a simplified, explicit intermediate representation for the BEAM. It's what Elixir, LFE, and other BEAM languages compile to. The OTP function `:compile.forms/2` or `:compile.file/2` compiles Core Erlang to `.beam` bytecode.

Key Core Erlang concepts:
- All variables are single-assignment
- All functions are explicitly named with arity
- Pattern matching is lowered to `case` expressions
- No syntactic sugar — everything is explicit
- Module attributes, exports, and function definitions

```erlang
%% Example Core Erlang output for a simple Skein function
module 'my_module' ['hello'/1]
  attributes []

'hello'/1 = fun (Name) ->
  let <Greeting> = call 'erlang':'+'(<<"Hello, ">>, Name)
  in Greeting
```

Use the `:cerl` module in Erlang to programmatically construct Core Erlang AST nodes. This is more reliable than generating Core Erlang text.

```elixir
# Building Core Erlang AST programmatically
:cerl.c_module(
  :cerl.c_atom(:my_module),
  [cerl.c_fname(:hello, 1)],
  [],
  [function_def]
)
```

## Important Design Constraints to Remember

1. **One way to do things.** If you're adding a language feature and there's already a way to do it, don't add the new one. Always check the spec first.

2. **The spec must fit in 128K tokens.** If a feature would bloat the spec significantly, it needs extraordinary justification.

3. **Types generate schemas.** Every named type must be derivable to JSON Schema. If a type construct can't derive a schema, reconsider the construct.

4. **Effects require capabilities.** Any function that performs I/O must be checked against declared capabilities. No exceptions (the FFI escape hatch is explicitly marked as unsafe).

5. **Errors are structured.** Every compiler error must produce JSON-serializable output with `fix_hint` and `fix_code`. This is not optional — it's a core feature for agent-writability.

6. **Agent transitions are compile-time checked.** The `Phase` enum with `->` transition declarations must be validated by the analyzer. Invalid transitions are compiler errors.

## Phase 1 Acceptance Criteria (Reference)

> **Note:** All phases (1-8f) are complete. This section is retained as a reference for the foundational compilation pipeline.

Phase 1 is "Hello BEAM" — prove the compilation pipeline works end-to-end.

A Phase 1 demo should:
1. Take a `.skein` file containing a module with one function
2. Lex it into tokens
3. Parse it into an AST
4. Generate Core Erlang
5. Compile to a `.beam` file
6. Load and call the function from an Elixir test

```
-- hello.skein
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
```

```elixir
# test
{:module, mod} = Skein.Compiler.compile_file("hello.skein")
assert mod.greet("world") == "Hello, world!"
```

When this works, Phase 1 is done. Move to Phase 2.

## Quick Reference: Running Things

```bash
# Setup
mix deps.get

# Compile the compiler itself
mix compile

# Run compiler tests
mix test

# Format code
mix format

# Compile a Skein file (once CLI exists)
mix skein.compile path/to/file.skein

# Run spec tests (once test harness exists)
mix skein.spec
```

## Documentation Site

Published documentation lives at https://kormie.github.io/Skein/ and is built with Astro + Starlight from source in `docs/site/`.

- **Agent entry point:** https://kormie.github.io/Skein/llms.txt
- **Full docs for agents:** https://kormie.github.io/Skein/llms-full.txt
- **Compact docs for agents:** https://kormie.github.io/Skein/llms-small.txt
- **Site config:** `.docs-config.json` (source mappings, sections, terminology)
- **Build:** `cd docs/site && bun install && bunx astro build`
- **Dev server:** `cd docs/site && bunx astro dev`

## Claude Plugins and Skills

The `github-pages-astro` plugin (`.claude/plugins/github-pages-astro/`) provides documentation site tooling:

### Slash Commands

| Command | Description |
|---------|-------------|
| `/docs-init` | Scaffold an Astro + Starlight site and generate `.docs-config.json` |
| `/docs-build` | Build the docs site and validate `llms.txt` output |
| `/docs-dev` | Start the Astro dev server for live preview |
| `/docs-sync` | Audit documentation freshness against the codebase |

### Skills (auto-activated)

| Skill | Description |
|-------|-------------|
| `docs-site` | Authoring and maintaining Astro + Starlight pages using `.docs-config.json` |
| `dual-docs` | Writing documentation that serves both human readers and AI agents |

### Hooks

- **Stop:** Runs `docs-freshness-check.sh` (warns about stale docs on session end)
- **SessionEnd:** Runs `stop-dev-server.sh` (cleans up any running Astro dev server)

## Session Memory

Accumulated learnings, gotchas, and project state are stored in `.claude/memory/MEMORY.md`. Consult this file at the start of each session for up-to-date context on completed phases, known pitfalls (e.g., `input` is a keyword, `stop()` needs parens, GenServer race conditions in tests), architecture notes, and user preferences.

## What Not To Do

- Don't build a package manager yet. The standard library is the only dependency for now.
- Don't build the web IDE yet. CLI-first.
- Don't optimize the compiler. Correctness first, performance later.
- Don't implement `extern`/FFI yet. Get the core language working first.
- Don't implement the managed deployment platform. Local dev only for now.
- Don't implement hot code upgrades. Standard restart-based deployment is fine initially.
