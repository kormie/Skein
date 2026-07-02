---
title: Project Structure
description: How the Skein codebase is organized.
---

## Umbrella Layout

Skein is an Elixir umbrella project with four apps:

```
skein/
├── mix.exs                          # Root umbrella config
├── CLAUDE.md                        # Project instructions and conventions
├── docs/
│   ├── SKEIN_SPEC.md                # Complete language specification
│   ├── ARCHITECTURE.md              # Compiler and runtime architecture
│   ├── ROADMAP.md                   # Canonical prioritized work list
│   ├── STABILITY.md                 # Versioning and stability policy
│   ├── skein_first_principles.md    # Language design philosophy
│   └── site/                        # This documentation site (Astro + Starlight)
├── examples/                        # Canonical .skein programs (all compile-tested)
│   ├── hello.skein
│   ├── hello_http.skein
│   ├── hello_llm.skein
│   ├── refund_agent.skein
│   ├── incident_triage.skein
│   ├── queue_worker.skein
│   ├── supervisor_pool.skein
│   ├── pubsub_notifications.skein
│   ├── semantic_search.skein
│   ├── ...
│   └── market_research/             # Multi-file example (agent + service)
├── editors/
│   └── vscode/                      # VS Code extension
│       ├── package.json             # Extension manifest
│       ├── skein.tmLanguage.json    # TextMate grammar
│       ├── snippets/skein.json      # 30+ snippets
│       └── src/extension.ts         # LSP client (TypeScript)
└── apps/
    ├── skein_compiler/              # Lexer, parser, analyzer, code generator
    ├── skein_runtime/               # OTP behaviours and runtime support
    ├── skein_cli/                   # CLI tooling (skein new, build, test, run, ...)
    └── skein_lsp/                   # Language Server Protocol implementation
```

## Compiler App (`apps/skein_compiler/`)

The full pipeline: source text → tokens → AST → annotated AST → Core Erlang → BEAM bytecode.

```
skein_compiler/
├── mix.exs
├── lib/
│   ├── skein_compiler.ex                # Entry point: compile_string/1, compile_file/1
│   └── skein/
│       ├── lexer.ex                     # Tokenizer (hand-written binary matching)
│       ├── parser.ex                    # Hand-written recursive descent parser
│       ├── ast.ex                       # AST node struct definitions
│       ├── analyzer.ex                  # Type, capability, transition, and guard checking
│       ├── error.ex                     # Structured, JSON-serializable error type
│       └── codegen/
│           ├── core_erlang.ex           # AST -> Core Erlang -> BEAM bytecode
│           └── schema_gen.ex            # Type declarations -> JSON Schema
└── test/                                # Unit, integration, and property-based tests
```

The analyzer is the largest stage of the pipeline and one of Skein's headline
features: it performs type checking and inference, capability checking
(every effect call must be covered by a declared capability), agent phase
transition validation, and match/guard analysis — all before any code is
generated.

## Runtime App (`apps/skein_runtime/`)

OTP behaviours and libraries that compiled Skein programs link against:
the `gen_statem`-based agent runtime, handler dispatch (HTTP/queue/schedule),
the tool registry, runtime capability enforcement, scoped KV memory, the
schema-checked ETS-backed store, the LLM client with pluggable backends,
the trace/event store with replay, and the Bandit + Plug HTTP server.

## CLI App (`apps/skein_cli/`)

The `skein` command-line tool: project scaffolding (`new`, `agents`),
compiling (`compile`, `build`), testing (`test`), running (`run`), trace
inspection (`trace`), shell `completions`, and stdio servers for editors
and coding agents (`lsp`, `mcp`). Packaged as a standalone binary with
Burrito.

## LSP App (`apps/skein_lsp/`)

The language server behind the VS Code extension — diagnostics, hover,
go-to-definition, completions, document symbols, and semantic tokens,
built on GenLSP and reusing the compiler for analysis.

## Dependencies

All dependencies are sourced from [hex.pm](https://hex.pm):

### Compiler (`skein_compiler`)

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `jason` | ~> 1.4 | JSON encoding for structured errors and schema gen |
| `stream_data` | ~> 1.1 | Property-based testing generators (test/dev only) |
| `propcheck` | ~> 1.4 | Stateful property testing via PropEr (test/dev only) |

### Runtime (`skein_runtime`)

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `bandit` | ~> 1.6 | HTTP server |
| `plug` | ~> 1.16 | HTTP middleware |
| `ecto` / `ecto_sql` | ~> 3.12 | Data layer |
| `ecto_sqlite3` | ~> 0.17 | SQLite adapter for local dev |
| `telemetry` | ~> 1.3 | Instrumentation |

### CLI (`skein_cli`)

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `burrito` | ~> 1.5 | Standalone binary packaging (wraps OTP release + ERTS) |

## Key Files

### `lib/skein_compiler.ex`

The main entry point orchestrating the pipeline:

```elixir
def compile_string(source) do
  with {:ok, tokens} <- Lexer.tokenize(source),
       {:ok, ast} <- Parser.parse(tokens),
       {:ok, annotated_ast} <- Analyzer.analyze(ast, source_text: source),
       {:ok, modules} <- CoreErlang.generate(annotated_ast) do
    load_modules(modules, ~c"nofile")
  end
end
```

Returns `{:module, module()}` on success or `{:error, [Skein.Error.t()]}` on failure. Code generation can produce multiple BEAM modules from one source file (agents nested in a module compile to their own modules).

### `lib/skein/ast.ex`

All AST node types as Elixir structs. Every node has a `meta` field carrying `%{line: int, col: int, file: string}` for source location tracking. Key nodes:

- **Top-level:** `Module`, `Fn`, `TypeDecl`, `EnumDecl`, `Capability`, `Agent`, `ToolDecl`, `Supervisor`, `Handler`, `Test`, `Scenario`, `Golden`
- **Expressions:** `BinaryOp`, `UnaryOp`, `Call`, `Pipe`, `FieldAccess`, `Let`, `Match`, `Block`
- **Literals:** `IntLit`, `FloatLit`, `BoolLit`, `StringLit`, `ListLit`, `MapLit`, `Identifier`
- **Types:** `TypeRef`, `Field`, `Variant`, `Annotation`

### `lib/skein/error.ex`

Structured errors designed for both human and LLM consumption:

```elixir
%Skein.Error{
  code: "E0001",
  severity: :error,
  message: "Unexpected character: ;",
  location: %{file: "hello.skein", line: 5, col: 12},
  fix_hint: "Skein does not use semicolons; a statement ends at the end of the line",
  fix_code: ""
}
```
