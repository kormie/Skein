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
│   ├── IMPLEMENTATION_PLAN.md       # 7-phase build plan
│   └── skein_first_principles.md    # Language design philosophy
├── examples/                        # Canonical .skein programs
│   ├── hello.skein
│   ├── hello_http.skein
│   ├── refund_agent.skein
│   ├── incident_triage.skein
│   └── queue_worker.skein
├── editors/
│   └── vscode/                      # VS Code extension
│       ├── package.json             # Extension manifest
│       ├── skein.tmLanguage.json    # TextMate grammar
│       ├── snippets/skein.json      # 30+ snippets
│       └── src/extension.ts         # LSP client (TypeScript)
├── apps/
│   ├── skein_compiler/              # Lexer, parser, analyzer, code generator
│   ├── skein_runtime/               # OTP behaviours and runtime support
│   ├── skein_cli/                   # CLI tooling
│   └── skein_lsp/                   # Language Server Protocol implementation
└── spec/                            # Language test suite (future)
```

## Compiler App (`apps/skein_compiler/`)

This is where all current implementation lives:

```
skein_compiler/
├── mix.exs
├── lib/
│   ├── skein_compiler.ex                # Entry point: compile_string/1, compile_file/1
│   └── skein/
│       ├── lexer.ex                     # Tokenizer (~441 lines)
│       ├── parser.ex                    # Recursive descent parser (~1200 lines)
│       ├── ast.ex                       # AST node struct definitions (~52 lines)
│       ├── analyzer.ex                  # Pass-through stub (~17 lines)
│       ├── error.ex                     # Structured error type (~31 lines)
│       └── codegen/
│           └── core_erlang.ex           # Core Erlang code generator (~480 lines)
└── test/
    └── skein/
        ├── lexer_test.exs               # 69 unit tests
        ├── lexer_property_test.exs      # 11 property tests
        ├── parser_test.exs              # 47 unit tests
        ├── parser_property_test.exs     # 8 property tests
        └── codegen/
            ├── core_erlang_test.exs     # 18 integration tests
            └── core_erlang_property_test.exs  # 9 property tests
```

## Dependencies

All dependencies use git sources (hex.pm is unreachable in the development environment):

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `nimble_parsec` | v1.4.2 | PEG parser combinator (used by lexer) |
| `jason` | v1.4.4 | JSON encoding for structured errors and schema gen |
| `stream_data` | v1.1.2 | Property-based testing generators (test/dev only) |
| `propcheck` | v1.4.2 | Stateful property testing via PropEr (test/dev only) |
| `libgraph` | 0.13.3 | Graph library, transitive dep of propcheck (override) |

The `libgraph` dependency uses `override: true` to replace propcheck's transitive hex.pm dependency with a git source.

## Key Files

### `lib/skein_compiler.ex`

The main entry point orchestrating the pipeline:

```elixir
def compile_string(source) do
  with {:ok, tokens} <- Lexer.tokenize(source),
       {:ok, ast} <- Parser.parse(tokens),
       {:ok, annotated_ast} <- Analyzer.analyze(ast),
       {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
    module_name = module_name_from_ast(annotated_ast)
    :code.load_binary(module_name, ~c"nofile", beam_binary)
  end
end
```

Returns `{:module, module()}` on success or `{:error, [Skein.Error.t()]}` on failure.

### `lib/skein/ast.ex`

All AST node types as Elixir structs. Every node has a `meta` field carrying `%{line: int, col: int, file: string}` for source location tracking. Key nodes:

- **Top-level:** `Module`, `Fn`, `TypeDecl`, `EnumDecl`, `Capability`
- **Expressions:** `BinaryOp`, `UnaryOp`, `Call`, `Pipe`, `FieldAccess`, `Let`, `Match`, `Block`
- **Literals:** `IntLit`, `FloatLit`, `BoolLit`, `StringLit`, `Identifier`
- **Types:** `TypeRef`, `Field`

### `lib/skein/error.ex`

Structured errors designed for both human and LLM consumption:

```elixir
%Skein.Error{
  code: "E001",
  severity: :error,
  message: "Unexpected token",
  location: %{file: "hello.skein", line: 5, col: 12},
  fix_hint: "Expected '}' to close module block",
  fix_code: "}"
}
```
