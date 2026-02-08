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
3. **Analyzer** (`Skein.Analyzer`) — AST to annotated AST (4 passes: name resolution, type checking, capability checking, transition checking)
4. **CodeGen** (`Skein.Codegen.CoreErlang`) — AST to Core Erlang to BEAM bytecode

## Key Modules

### Compiler

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Lexer` | `apps/skein_compiler/lib/skein/lexer.ex` | Tokenizer |
| `Skein.Parser` | `apps/skein_compiler/lib/skein/parser.ex` | AST construction |
| `Skein.AST` | `apps/skein_compiler/lib/skein/ast.ex` | AST node definitions |
| `Skein.Analyzer` | `apps/skein_compiler/lib/skein/analyzer.ex` | Type + capability checking |
| `Skein.Codegen.CoreErlang` | `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` | Code generation |
| `Skein.Codegen.SchemaGen` | `apps/skein_compiler/lib/skein/codegen/schema_gen.ex` | JSON Schema derivation |
| `Skein.Error` | `apps/skein_compiler/lib/skein/error.ex` | Structured error types |
| `Skein.Compiler` | `apps/skein_compiler/lib/skein_compiler.ex` | Pipeline entry point |

### Runtime

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Runtime.Agent` | `apps/skein_runtime/lib/skein/runtime/agent.ex` | GenStateMachine agent lifecycle |
| `Skein.Runtime.Http` | `apps/skein_runtime/lib/skein/runtime/http.ex` | HTTP client with capability enforcement |
| `Skein.Runtime.Capability` | `apps/skein_runtime/lib/skein/runtime/capability.ex` | Runtime capability validation |
| `Skein.Runtime.Handler` | `apps/skein_runtime/lib/skein/runtime/handler.ex` | HTTP request dispatch |
| `Skein.Runtime.Store` | `apps/skein_runtime/lib/skein/runtime/store.ex` | ETS-backed storage (default) |
| `Skein.Runtime.StoreEcto` | `apps/skein_runtime/lib/skein/runtime/store_ecto.ex` | Ecto/SQLite-backed storage |
| `Skein.Runtime.EctoSchema` | `apps/skein_runtime/lib/skein/runtime/ecto_schema.ex` | Dynamic Ecto schema generation |
| `Skein.Runtime.MigrationGen` | `apps/skein_runtime/lib/skein/runtime/migration_gen.ex` | Ecto migration generation |
| `Skein.Runtime.Repo` | `apps/skein_runtime/lib/skein/runtime/repo.ex` | Ecto Repo (SQLite3) |
| `Skein.Runtime.Memory` | `apps/skein_runtime/lib/skein/runtime/memory.ex` | Scoped KV memory |
| `Skein.Runtime.Llm` | `apps/skein_runtime/lib/skein/runtime/llm.ex` | LLM client with schema-constrained JSON |
| `Skein.Runtime.Server` | `apps/skein_runtime/lib/skein/runtime/server.ex` | HTTP server |
| `Skein.Runtime.Trace` | `apps/skein_runtime/lib/skein/runtime/trace.ex` | Trace span recording |

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

Phases 1-5 are complete and Phase 6 is in progress (agents, memory, and LLM done; tools and supervision remaining). The compilation pipeline supports:
- Modules with functions, let bindings, match expressions, pipes, string interpolation
- Type checking with inference, JSON schema derivation, constraint annotations
- Capability-based security with compile-time and runtime enforcement
- HTTP handlers with route matching and path parameters
- ETS-backed store operations with capability gating
- Agent state machines with phase transitions, compile-time transition validation
- Scoped KV memory with namespace isolation
- LLM client with pluggable backends and schema-constrained JSON
- Automatic trace recording for all effect calls

**Test suite:** 81 properties, 779 tests, 0 failures
