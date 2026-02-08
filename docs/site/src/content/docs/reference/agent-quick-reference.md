---
title: Agent Quick Reference
description: Complete reference for AI agents working with the Skein language project — conventions, structure, commands, and rules in one page.
sidebar:
  order: 1
---

## Project Identity

Skein is a programming language that compiles to BEAM bytecode and runs on the Erlang VM (OTP). The compiler and toolchain are implemented in Elixir. Skein is designed for building cloud services where AI agents are first-class constructs.

## Repository Structure

```
skein/
├── mix.exs                      # Root umbrella project
├── CLAUDE.md                    # Agent instructions
├── .docs-config.json            # Documentation site config
├── docs/
│   ├── SKEIN_SPEC.md            # Complete language specification
│   ├── ARCHITECTURE.md          # Compiler and runtime architecture
│   ├── IMPLEMENTATION_PLAN.md   # Phased build plan
│   └── site/                    # Astro + Starlight documentation site
├── apps/
│   ├── skein_compiler/          # Lexer, parser, analyzer, code generator
│   ├── skein_runtime/           # OTP behaviours and runtime support
│   └── skein_cli/               # CLI tooling
├── examples/                    # Canonical .skein programs
└── spec/                        # Language test suite
```

## Technology Stack

| Component | Choice |
|-----------|--------|
| Compiler language | Elixir |
| Lexer | NimbleParsec |
| Parser | Hand-written recursive descent |
| IR target | Core Erlang |
| Agent runtime | gen_statem (GenStateMachine) |
| HTTP server | Bandit + Plug |
| Storage | Ecto + Postgres |
| Testing | ExUnit + StreamData + PropCheck |

## Commands

| Command | Purpose |
|---------|---------|
| `mix deps.get` | Install dependencies |
| `mix compile` | Compile the compiler |
| `mix test` | Run all tests |
| `mix format` | Format code |

## Compilation Pipeline

Source (.skein) → Lexer → Parser → Analyzer → CodeGen → BEAM bytecode

1. **Lexer** (`Skein.Lexer`) — source text to token stream
2. **Parser** (`Skein.Parser`) — token stream to AST
3. **Analyzer** (`Skein.Analyzer`) — AST to annotated AST (stub in Phase 1)
4. **CodeGen** (`Skein.Codegen.CoreErlang`) — AST to Core Erlang to BEAM bytecode

## Key Modules

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Lexer` | `apps/skein_compiler/lib/skein/lexer.ex` | Tokenizer |
| `Skein.Parser` | `apps/skein_compiler/lib/skein/parser.ex` | AST construction |
| `Skein.AST` | `apps/skein_compiler/lib/skein/ast.ex` | AST node definitions |
| `Skein.Codegen.CoreErlang` | `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` | Code generation |
| `Skein.Error` | `apps/skein_compiler/lib/skein/error.ex` | Structured error types |
| `Skein.Compiler` | `apps/skein_compiler/lib/skein_compiler.ex` | Pipeline entry point |

## Coding Conventions

- Follow `mix format` style
- Typespecs (`@spec`) on all public functions
- `@moduledoc` and `@doc` on all public modules and functions
- Pattern match in function heads over case/cond
- Pipe operator for data transformations
- `{:ok, result}` / `{:error, errors}` tuples throughout the pipeline
- TDD is mandatory — tests before or alongside implementation

## Error Format

Every compiler error is a `%Skein.Error{}` struct with fields: `code`, `severity`, `message`, `location`, `context`, `fix_hint`, `fix_code`. Errors serialize to JSON.

## Terminology

| Canonical Term | Do Not Use |
|---------------|------------|
| agent | bot, assistant |
| module | class, package |
| handler | endpoint, route |
| phase | state, stage |
| capability | permission, privilege |

## Current Status

Phase 1 ("Hello BEAM") is complete. The end-to-end compilation pipeline works for modules with functions, let bindings, match expressions, arithmetic, comparisons, string interpolation, and pipe operators.
