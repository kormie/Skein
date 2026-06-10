# Skein Language for VS Code

Full language support for the [Skein programming language](https://kormie.github.io/Skein/) — a language that compiles to BEAM bytecode, designed for building cloud services where AI agents are first-class constructs.

## Features

### Syntax Highlighting

Rich TextMate grammar with specialized scoping for:
- Module, agent, handler, tool, and supervisor declarations
- Phase enum transitions
- Effect operations (`llm.chat`, `memory.put`, `store.get`, etc.)
- String interpolation (`"Hello, ${name}!"`)
- Annotations (`@description`, `@min`, `@primary`)
- HTTP methods, queue names, cron schedules

### Language Server (LSP)

Full Language Server Protocol support powered by the Skein compiler:

- **Diagnostics** — Real-time compiler errors and warnings as you type
- **Document Symbols** — Navigate modules, functions, handlers, types, and agents in the outline view
- **Hover** — Type information and documentation for functions, types, and built-in primitives
- **Go-to-Definition** — Jump to function and type definitions
- **Code Completion** — Context-aware completions for keywords, types, effect methods, user symbols, and annotations
- **Semantic Tokens** — Enhanced semantic highlighting beyond TextMate grammar

### Snippets

30+ snippets for common patterns:
- `module` — Module scaffold
- `agent` — Agent with state machine
- `fn` — Function definition
- `handler http get/post/put/patch/delete` — HTTP handlers
- `handler queue` / `handler schedule` / `handler topic` — Event handlers
- `tool` — Tool definition with input/output/errors
- `match` — Pattern match expression
- `test` / `scenario` / `golden` — Test constructs
- `llm.chat` / `llm.json` / `memory.put` / `memory.get` — Effect calls
- And more...

## Requirements

- VS Code 1.80+
- For the language server, one of:
  - the standalone `skein` binary (v0.1.3+) on your `PATH` — no Elixir needed
    ([install instructions](https://github.com/kormie/Skein#getting-started)), or
  - an Elixir/OTP checkout of the Skein repo (the extension runs `mix skein.lsp`)

Syntax highlighting and snippets work with no requirements at all.

## Extension Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `skein.lsp.enabled` | `true` | Enable/disable the language server |
| `skein.lsp.serverCommand` | `"auto"` | `skein` (standalone binary), `mix` (compiler checkout), or `auto` (mix only inside the Skein repo) |
| `skein.lsp.skeinPath` | `"skein"` | Path to the `skein` binary |
| `skein.lsp.path` | `""` | Working directory for the server (defaults to workspace root) |
| `skein.lsp.mixCommand` | `"mix"` | Path to the `mix` executable (mix mode only) |
| `skein.trace.server` | `"off"` | Trace LSP communication (`off`, `messages`, `verbose`) |

## Commands

| Command | Description |
|---------|-------------|
| `Skein: Restart Language Server` | Restart the LSP after changing settings or updating the binary |
| `Skein: Show Language Server Output` | Open the server's output channel for troubleshooting |

## Installing

### From a GitHub Release (easiest)

Every release ships a prebuilt `skein-vscode.vsix` — download it from the
[Releases page](https://github.com/kormie/Skein/releases) and install:

```bash
code --install-extension skein-vscode.vsix
```

## Development

### Building the Extension

```bash
cd editors/vscode
npm install
npm run compile
```

### Packaging

```bash
npm run package
# Produces a .vsix file
```

### Installing from VSIX

```
code --install-extension skein-lang-0.1.2.vsix
```

## Architecture

The extension consists of two parts:

1. **VS Code Client** (TypeScript) — Manages the editor integration, starts the language server, and communicates over stdio
2. **Skein Language Server** (Elixir) — An OTP application (`skein_lsp`) built with [GenLSP](https://github.com/elixir-tools/gen_lsp) that uses the Skein compiler for analysis

The language server runs as `skein lsp` (standalone binary) or `mix skein.lsp` (compiler checkout) and communicates via stdin/stdout.
