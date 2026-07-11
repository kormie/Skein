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
│   ├── ROADMAP.md               # Development roadmap
│   └── site/                    # Astro + Starlight documentation site
├── editors/
│   └── vscode/                  # VS Code extension (grammar, snippets, LSP client)
├── apps/
│   ├── skein_compiler/          # Lexer, parser, analyzer, code generator
│   ├── skein_runtime/           # OTP behaviours and runtime support
│   ├── skein_cli/               # CLI tooling
│   └── skein_lsp/               # Language Server Protocol implementation
└── examples/                    # Canonical .skein programs
```

## Technology Stack

| Component | Choice |
|-----------|--------|
| Compiler language | Elixir |
| Lexer | Hand-written binary matching |
| Parser | Hand-written recursive descent |
| IR target | Core Erlang |
| Agent runtime | OTP's `:gen_statem` (used directly) |
| HTTP server | Bandit + Plug |
| Storage | Ecto + SQLite3 |
| Language server | GenLSP |
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
3. **Analyzer** (`Skein.Analyzer`) — AST to annotated AST (multi-pass: name resolution, type checking, capability checking, transition checking, plus lint passes for unused bindings/capabilities and unreachable code)
4. **CodeGen** (`Skein.CodeGen.CoreErlang`) — AST to Core Erlang to BEAM bytecode

## Key Modules

### Compiler

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Lexer` | `apps/skein_compiler/lib/skein/lexer.ex` | Tokenizer |
| `Skein.Parser` | `apps/skein_compiler/lib/skein/parser.ex` | AST construction |
| `Skein.AST` | `apps/skein_compiler/lib/skein/ast.ex` | AST node definitions |
| `Skein.Analyzer` | `apps/skein_compiler/lib/skein/analyzer.ex` | Type + capability checking |
| `Skein.CodeGen.CoreErlang` | `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` | Code generation |
| `Skein.CodeGen.SchemaGen` | `apps/skein_compiler/lib/skein/codegen/schema_gen.ex` | JSON Schema derivation |
| `Skein.Error` | `apps/skein_compiler/lib/skein/error.ex` | Structured error types |
| `Skein.Compiler` | `apps/skein_compiler/lib/skein_compiler.ex` | Pipeline entry point |

### Runtime

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Runtime.Agent` | `apps/skein_runtime/lib/skein/runtime/agent.ex` | `:gen_statem`-based agent lifecycle |
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

### Language Server

| Module | Location | Purpose |
|--------|----------|---------|
| `Skein.Lsp.Server` | `apps/skein_lsp/lib/skein/lsp/server.ex` | Main LSP server |
| `Skein.Lsp.Diagnostics` | `apps/skein_lsp/lib/skein/lsp/diagnostics.ex` | Compiler error → LSP diagnostic |
| `Skein.Lsp.Symbols` | `apps/skein_lsp/lib/skein/lsp/symbols.ex` | Document symbol extraction |
| `Skein.Lsp.HoverProvider` | `apps/skein_lsp/lib/skein/lsp/hover_provider.ex` | Hover info and go-to-definition |
| `Skein.Lsp.Completions` | `apps/skein_lsp/lib/skein/lsp/completions.ex` | Context-aware code completion |
| `Skein.Lsp.SemanticTokens` | `apps/skein_lsp/lib/skein/lsp/semantic_tokens.ex` | Semantic token encoding |

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

Pre-1.0 RC gate active. The end-to-end pipeline is functional and the frozen 1.0 surfaces are guarded by conformance tests; GA still waits on the rc.5 soak. The full compilation pipeline supports:
- Modules with functions, let bindings, match expressions, pipes, string interpolation
- Type checking with inference, JSON schema derivation, constraint annotations
- Capability-based security with compile-time and runtime enforcement
- HTTP/queue/schedule handlers with route matching and path parameters
- ETS-backed store operations with capability gating and typed tables (C5, #255) — `capability store.table("users", User)` names the record type, operations are type-checked, writes are schema-checked at runtime (compiled programs use the ETS path; EventStore persistence uses SQLite)
- Agent state machines with phase transitions, compile-time transition validation
- Scoped KV memory with namespace isolation
- LLM client with pluggable backends, schema-validated JSON decoding for `llm.json[T]` (responses are recursively validated against the derived schema — C3, #298; violations are `Err(LlmError.InvalidSchema(violations))`), and streaming
- Automatic trace recording for all effect calls
- Full CLI tooling (new, build, test, run, trace)
- VS Code extension with LSP (diagnostics, symbols, hover, completions, go-to-definition)

**Test suite:** the full umbrella unit and property suites run green — see CI for current counts
