---
title: VS Code Extension
description: Full language support for Skein in Visual Studio Code — syntax highlighting, diagnostics, completions, hover, go-to-definition, and more.
---

The Skein VS Code extension provides a complete editing experience powered by a Language Server Protocol (LSP) implementation built on top of the Skein compiler.

## Installation

### From Source

```bash
cd editors/vscode
npm install
npm run compile
```

Then in VS Code, use **Extensions: Install from VSIX** or run:

```bash
code --install-extension skein-lang-0.1.0.vsix
```

### Requirements

- VS Code 1.80+
- Elixir/OTP installed and on your `PATH`
- A Skein project with `mix.exs` in the workspace root

## Features

### Syntax Highlighting

The extension includes a comprehensive TextMate grammar with specialized scoping for all Skein constructs:

- **Declarations** — `module`, `agent`, `handler`, `tool`, `supervisor`, `type`, `enum`, `fn`
- **Agent constructs** — `on start`, `on phase`, `transition`, `stop`, `emit`
- **Handler types** — HTTP (with method + route), queue, schedule, topic
- **Effect operations** — `llm.chat`, `memory.put`, `store.get`, `respond.json`, etc.
- **String interpolation** — Full recursive highlighting inside `${...}`
- **Annotations** — `@description("...")`, `@min(0)`, `@primary`
- **Constants** — `true`, `false`, `Ok`, `Err`, `Some`, `None`

### Diagnostics

Real-time compiler errors and warnings appear as you type. The language server runs the full Skein compilation pipeline (lexer → parser → analyzer) and reports all errors with:

- Error codes (e.g., `E0001`, `E0020`, `E0012`)
- Source locations with underline highlights
- Fix hints explaining how to resolve the error

```skein
module Hello {
  fn greet() -> String {
    http.get("https://example.com")
    -- ^^^^^ [E0012] Missing capability for effect call
    -- Hint: Add 'capability http.out' to the module
  }
}
```

### Document Symbols

The outline view shows the structure of your `.skein` files:

- Modules and agents (top-level)
- Functions with parameter signatures
- Handlers (HTTP, queue, schedule)
- Type and enum declarations with fields/variants
- State fields (for agents)
- Phase enum with variants
- Tests, scenarios, and golden tests

Use `Ctrl+Shift+O` (or `Cmd+Shift+O` on macOS) to jump to any symbol.

### Hover Information

Hover over any symbol to see its type information:

- **Functions** — Full signature with parameter types and return type
- **Types** — Field listing with types
- **Enums** — Variant listing
- **Phase variants** — Allowed transitions
- **Built-in types** — Description (e.g., "64-bit signed integer")
- **State fields** — Type annotation

### Go-to-Definition

`Ctrl+Click` (or `F12`) on a function or type name to jump to its definition within the file.

### Code Completion

Context-aware completions triggered automatically or with `Ctrl+Space`:

| Context | Completions |
|---------|-------------|
| General | Keywords, types, user-defined symbols, effect namespaces |
| After `.` | Methods for the namespace (`llm.` → `chat`, `json`, `stream`) |
| After `@` | Annotation names (`@description`, `@min`, `@max`, etc.) |
| Type position | Built-in and user-defined types |

Supported effect namespaces: `llm`, `memory`, `store`, `http`, `topic`, `queue`, `trace`, `config`, `secret`, `stream`, `respond`.

### Semantic Tokens

Enhanced highlighting beyond TextMate grammar, powered by the Skein lexer. Provides accurate token classification for keywords, types, variables, operators, and more.

### Snippets

30+ snippets for common patterns. Type the prefix and press `Tab`:

| Prefix | Expands to |
|--------|-----------|
| `module` | Module scaffold |
| `agent` | Agent with state, phases, and start handler |
| `fn` | Function definition |
| `let` | Let binding |
| `match` | Match expression with arms |
| `handler http get` | HTTP GET handler |
| `handler http post` | HTTP POST handler |
| `handler queue` | Queue handler |
| `handler schedule` | Schedule handler |
| `tool` | Full tool declaration |
| `supervisor` | Supervisor declaration |
| `test` | Test with assert |
| `scenario` | Scenario with given/expect |
| `golden` | Golden trace test |
| `emit` | Emit event |
| `transition` | Phase transition |
| `respond` | JSON response |
| `llm.chat` | LLM chat call |
| `llm.json` | Structured LLM call |
| `memory.put` | Store to memory |
| `memory.get` | Read from memory |
| `capability` | Capability declaration (with choices) |
| `httpmodule` | Full HTTP module with health check |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `skein.lsp.enabled` | `true` | Enable/disable the language server |
| `skein.lsp.path` | `""` | Path to the Skein project root |
| `skein.lsp.mixCommand` | `"mix"` | Path to the `mix` executable |
| `skein.trace.server` | `"off"` | LSP trace level: `off`, `messages`, `verbose` |

## Architecture

The extension has two components:

1. **VS Code Client** (TypeScript, `editors/vscode/src/extension.ts`) — Manages the editor integration and communicates with the language server over stdio
2. **Skein Language Server** (Elixir, `apps/skein_lsp/`) — An OTP application built with [GenLSP](https://github.com/elixir-tools/gen_lsp) that uses the Skein compiler for analysis

### Language Server Modules

| Module | Purpose |
|--------|---------|
| `Skein.Lsp.Server` | Main LSP server — request/notification handlers |
| `Skein.Lsp.Diagnostics` | Compiler error → LSP diagnostic conversion |
| `Skein.Lsp.Symbols` | AST → document symbol extraction |
| `Skein.Lsp.HoverProvider` | Symbol resolution, hover info, go-to-definition |
| `Skein.Lsp.Completions` | Context-aware completion engine |
| `Skein.Lsp.SemanticTokens` | Lexer-based semantic token encoding |

### Starting the Language Server

The language server is started via `mix skein.lsp` and communicates over stdin/stdout:

```bash
# Start manually (for debugging)
cd /path/to/skein-project
mix skein.lsp
```

The VS Code extension starts this automatically when a `.skein` file is opened.

## Troubleshooting

### Language server not starting

1. Ensure Elixir is installed and `mix` is on your `PATH`
2. Check the Output panel (**View > Output**, select "Skein Language Server")
3. Set `skein.trace.server` to `"verbose"` for detailed protocol logs
4. Verify the Skein project compiles: `mix compile` in the project root

### Diagnostics not appearing

1. Check that `skein.lsp.enabled` is `true`
2. Verify the file has a `.skein` extension
3. Check `skein.lsp.path` points to a directory with `mix.exs`
