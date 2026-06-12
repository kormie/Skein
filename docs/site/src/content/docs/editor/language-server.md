---
title: Language Server (LSP)
description: Technical details of the Skein Language Server Protocol implementation.
---

The Skein Language Server is an Elixir application (`skein_lsp`) that implements the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/). It uses the Skein compiler as its analysis engine.

## Capabilities

The server advertises these LSP capabilities:

| Capability | Description |
|-----------|-------------|
| `textDocument/publishDiagnostics` | Compile errors and warnings |
| `textDocument/documentSymbol` | Document outline (modules, functions, handlers) |
| `textDocument/hover` | Type information on hover |
| `textDocument/definition` | Go-to-definition for functions and types |
| `textDocument/completion` | Context-aware code completion |
| `textDocument/codeAction` | Quickfixes from each error's `fix_hint`/`fix_code` (missing tokens, missing capability lines, unused declarations) |
| `textDocument/semanticTokens/full` | Semantic highlighting |
| `textDocument/didOpen` | Document tracking |
| `textDocument/didChange` | Full document sync |
| `textDocument/didSave` | Save-triggered recompilation |
| `textDocument/didClose` | Document cleanup |

## How It Works

### Diagnostics Pipeline

When a document is opened, changed, or saved, the server runs the Skein compiler pipeline:

```
Source text
  │
  ├── Skein.Lexer.tokenize/1
  │     └── {:error, errors} → Lexer diagnostics
  │
  ├── Skein.Parser.parse/2
  │     └── {:error, errors} → Parser diagnostics
  │
  └── Skein.Analyzer.analyze/1
        ├── {:error, errors} → Analyzer diagnostics (AST still retained)
        └── {:ok, ast}       → No diagnostics
```

Each `Skein.Error` is converted to an LSP `Diagnostic` with:
- Position mapped from 1-indexed (Skein) to 0-indexed (LSP)
- Severity mapped from `:error`/`:warning` to LSP severity levels
- Error code and fix hint included in the message

### Symbol Extraction

The server walks the AST to extract symbols for the document outline:

| AST Node | Symbol Kind |
|----------|-------------|
| `Module` | Module |
| `Agent` | Class |
| `Fn` | Function |
| `TypeDecl` | Struct |
| `EnumDecl` | Enum |
| `Handler` | Event |
| `AgentHandler` | Event |
| `ToolDecl` | Interface |
| `Supervisor` | Namespace |
| `Test` / `Scenario` / `Golden` | Function |
| `Field` | Field |
| `Variant` | EnumMember |
| State fields | Property |

### Hover Resolution

The hover provider uses a name-based lookup strategy:

1. Extract the word at the cursor position
2. Search declarations in the current AST for a matching name
3. If no match, check built-in types (`Int`, `String`, `Option`, etc.)
4. Format the result as a Markdown code block with type signature

### Completion Engine

Completions are context-sensitive based on the text before the cursor:

| Context | Strategy |
|---------|----------|
| After `.` | Look up the namespace and return its methods |
| After `:` or `->` | Return type completions |
| After `@` | Return annotation names |
| General | Keywords + types + user symbols + effect namespaces + snippets |

## Implementation

The LSP server is built with [GenLSP](https://github.com/elixir-tools/gen_lsp), which provides:

- OTP behaviour for LSP process management
- Typed structs for all LSP protocol messages
- Stdio communication transport
- Built-in error handling (exceptions don't crash the server)

### Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `gen_lsp` | v0.11.3 | LSP behaviour and protocol types |
| `typed_struct` | v0.3.0 | Struct definitions (GenLSP dep) |
| `nimble_options` | v1.1.1 | Option validation (GenLSP dep) |
| `schematic` | v0.2.1 | Schema validation (GenLSP dep) |
| `skein_compiler` | in_umbrella | Skein lexer, parser, analyzer |

### Running the Server

```bash
# Via the standalone binary (used by the VS Code extension by default)
skein lsp

# Via mix task (inside a Skein compiler checkout)
mix skein.lsp

# Programmatically
SkeinLsp.start()
```

The server communicates over stdio using JSON-RPC as specified by the LSP protocol.

## Testing

The language server has a test suite covering all features (see CI for current counts):

```bash
mix test apps/skein_lsp/test/
```

Tests exercise each module directly without needing a running LSP process:

- **Diagnostics tests** — Valid source produces no diagnostics; invalid source produces correct error codes, locations, and severities
- **Symbols tests** — Modules produce correct symbol hierarchies; agents include state fields, phases, and handlers
- **Completion tests** — Keywords, types, effect namespaces, and method completions after `.`
- **Code action tests** — Quickfix edits for missing tokens (`E0001`), missing capabilities (`E0012`), unused capabilities (`W0002`), and unused bindings (`W0001`)
- **Hover tests** — Function signatures, built-in type descriptions
- **Semantic token tests** — Valid source encodes to groups-of-5 integers; invalid source returns empty
