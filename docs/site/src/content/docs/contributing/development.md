---
title: Development Guide
description: How to set up, build, test, and contribute to the Skein compiler.
---

## Environment Setup

### Requirements
- Elixir 1.19+ on OTP 28+
- Git

### Getting Started

```bash
git clone <repo-url> skein
cd skein
mix deps.get
mix compile
```

### Dependencies

All dependencies use git sources (no hex.pm required):

```bash
# Fetch dependencies
mix deps.get

# If a dependency fails to fetch, retry -- git can be flaky
mix deps.get
```

## Project Layout

Skein is an Elixir umbrella project:

```
skein/
  mix.exs               # Root umbrella (mix aliases for skein.* commands)
  apps/
    skein_compiler/      # Lexer, parser, analyzer, code generator
    skein_runtime/       # Agents, HTTP, handlers, store, memory, LLM, tools, trace
    skein_cli/           # CLI: new, build, test, run, trace
    skein_lsp/           # Language Server Protocol implementation (GenLSP)
  editors/
    vscode/              # VS Code extension (grammar, snippets, LSP client)
  docs/                  # Specifications and documentation
  examples/              # Example .skein programs
```

## Common Tasks

### Running Tests

```bash
# All tests (812 checks: 731 unit + 81 property)
mix test

# Verbose output
mix test --trace

# Just compiler tests
mix test apps/skein_compiler/test/

# Just runtime tests
mix test apps/skein_runtime/test/

# Just CLI tests
mix test apps/skein_cli/test/

# Just LSP tests
mix test apps/skein_lsp/test/

# Specific test file
mix test apps/skein_compiler/test/skein/parser_test.exs

# Specific test by line
mix test apps/skein_compiler/test/skein/lexer_test.exs:42
```

### Formatting Code

```bash
mix format
```

Always run `mix format` before committing. The project follows standard Elixir formatting.

### Interactive Development

```bash
cd apps/skein_compiler
iex -S mix
```

Then in IEx:

```elixir
# Compile a string
{:module, mod} = Skein.Compiler.compile_string(~S"""
module Test {
  fn hello() -> String {
    "world"
  }
}
""")
mod.hello()

# Inspect tokens
{:ok, tokens} = Skein.Lexer.tokenize("let x = 42")

# Inspect AST
{:ok, ast} = Skein.Parser.parse(tokens)
```

## Coding Conventions

### Elixir Style
- Follow standard `mix format`
- Use `@spec` on all public functions
- Use `@moduledoc` and `@doc` on all public modules and functions
- Pattern match in function heads over case/cond where possible
- Prefer pipe operator for data transformations
- No abbreviations except `ctx`, `opts`, `acc`

### Error Handling
- Never raise exceptions for user-facing errors
- Use `{:ok, result}` / `{:error, errors}` tuples throughout the pipeline
- Every error is a `%Skein.Error{}` struct that can serialize to JSON
- Include `fix_hint` and `fix_code` in errors where possible

### Testing
- **TDD is mandatory** -- write tests before or alongside implementation
- Every public function needs happy path and error case tests
- Use `~S` sigil for Skein source strings in tests (avoids interpolation conflicts)
- CodeGen tests must use `async: false` (they load BEAM modules)
- Property tests go alongside unit tests in separate `*_property_test.exs` files

### Git Conventions
- Branch naming: `phase-N/description` (e.g., `phase-1/lexer-core-tokens`)
- Commit messages: `[phase-N] component: description`
- Each phase is a PR

## Architecture Decisions

Key decisions that affect how you work on the compiler:

### Token Format
Tokens are tuples, not structs:
```elixir
{:keyword, {line, col}}           # no value
{:token_type, {line, col}, value} # with value
```

### AST Nodes
Every AST node is a struct with a `meta` field:
```elixir
%AST.Fn{
  name: "add",
  params: [...],
  return_type: %AST.TypeRef{},
  body: %AST.Block{},
  meta: %{line: 1, col: 3, file: "hello.skein"}
}
```

### Core Erlang Generation
Use `:cerl` module functions, not text generation:
```elixir
# Good: programmatic AST construction
:cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:+), [left, right])

# Bad: string templating
"call 'erlang':'+'(#{left}, #{right})"
```

### Variable Naming
Skein `snake_case` becomes Core Erlang `CamelCase`:
```elixir
"my_var" -> :MyVar
"x" -> :X
```

### Temporary Variables
Use `Process.get/put(:skein_var_counter, ...)` for unique variable generation during codegen.

## Working on the Language Server

The LSP server lives in `apps/skein_lsp/` and is built with [GenLSP](https://github.com/elixir-tools/gen_lsp). It provides IDE features by calling the Skein compiler API directly.

### Running the LSP

```bash
# Start the LSP server (stdio transport, used by VS Code)
mix skein.lsp
```

### LSP Modules

| Module | Purpose |
|--------|---------|
| `Skein.Lsp.Server` | Main GenLSP server, protocol request/notification handlers |
| `Skein.Lsp.Diagnostics` | Runs lexer→parser→analyzer, converts errors to LSP diagnostics |
| `Skein.Lsp.Symbols` | Extracts document symbols from AST |
| `Skein.Lsp.HoverProvider` | Hover info and go-to-definition |
| `Skein.Lsp.Completions` | Context-aware code completion |
| `Skein.Lsp.SemanticTokens` | Lexer-based semantic token encoding |

### Adding LSP Features

When adding a new compiler feature, also consider:
1. **Diagnostics** -- the LSP automatically picks up new compiler errors
2. **Symbols** -- if you add a new top-level construct, add it to `Symbols.document_symbols/1`
3. **Completions** -- if you add new keywords or built-in types, add them to `Completions`
4. **Hover** -- if you add new built-in types, add descriptions to `HoverProvider`

### VS Code Extension

The VS Code extension at `editors/vscode/` has two parts:
- **Static**: TextMate grammar (`skein.tmLanguage.json`), snippets (`snippets/skein.json`), language config
- **Dynamic**: TypeScript LSP client (`src/extension.ts`) that launches `mix skein.lsp`

To build the extension:
```bash
cd editors/vscode
npm install
npm run compile
```

## Adding a New Language Feature

General workflow for extending the compiler:

1. **Write the test first** -- what should the feature look like from the user's perspective?
2. **Extend the lexer** -- add any new tokens (if needed)
3. **Extend the parser** -- add the grammar production, build AST nodes
4. **Add AST node types** -- if new node types are needed
5. **Extend the analyzer** -- add type checking / validation (when analyzer is active)
6. **Extend the code generator** -- translate the new AST nodes to Core Erlang
7. **Add property tests** -- generators that exercise the new feature randomly
8. **Run all tests** -- `mix test` must pass with 0 failures

## Useful References

- `docs/SKEIN_SPEC.md` -- Complete language specification
- `docs/ARCHITECTURE.md` -- Compiler and runtime architecture
- `docs/IMPLEMENTATION_PLAN.md` -- 7-phase build plan with acceptance criteria
- `docs/skein_first_principles.md` -- Language design philosophy
- Erlang `:cerl` module docs -- `https://www.erlang.org/doc/apps/compiler/cerl`
- Core Erlang spec -- `https://www.it.uu.se/research/group/hipe/cerl/`
