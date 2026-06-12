---
title: Quickstart
description: Build and run your first Skein program in under 5 minutes.
---

## Install

One command — detects your platform, verifies the SHA-256 against the
release checksums, and installs to `~/.local/bin` (no root):

```bash
curl -fsSL https://kormie.github.io/Skein/install.sh | sh

skein version  # → skein 0.3.0
```

Pin a version with `SKEIN_VERSION=0.1.7`, or change the destination with
`SKEIN_BIN_DIR=/usr/local/bin`. The script is
[`install.sh`](https://github.com/kormie/Skein/blob/main/install.sh) if you
want to read it first.

Prefer manual installation? Grab the binary for your platform from the
[Releases page](https://github.com/kormie/Skein/releases)
(`skein-{linux,macos}-{x86_64,aarch64}`), `chmod +x` it, and put it on your
PATH.

No Erlang, Elixir, or other dependencies required — it's a self-contained binary.

## Create a Project

```bash
skein new hello_world
cd hello_world
```

This gives you:

```
hello_world/
  skein.toml            # project config (incl. LLM backend)
  src/main.skein        # module + tool + co-located test
  test/main_test.skein  # integration test through the module's tool
  AGENTS.md             # Skein primer for coding agents
  CLAUDE.md             # one-line pointer to AGENTS.md
  README.md
  .gitignore
```

The scaffold already runs: `src/main.skein` declares a function, a `test`
block next to it, and a tool — the one cross-module seam in Skein — and
`test/main_test.skein` exercises that tool the way another service or
agent would.

The project is also `git init`-ed for you (skip with `--no-git`), and
`AGENTS.md` / `CLAUDE.md` can be skipped with `--no-agents` or regenerated
later in any project with `skein agents`.

## Write Your First Program

Add functions to the `HelloWorld` module in `src/main.skein` (keep the
scaffolded tool and test — `test/main_test.skein` calls the tool):

```skein
module HelloWorld {
  fn hello(name: String) -> String {
    "Hello, ${name}!"
  }

  fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn classify(n: Int) -> String {
    match n > 0 {
      true  -> "positive"
      false -> "non-positive"
    }
  }

  -- Tools are how other modules and agents call into this one.
  tool HelloWorld.Greet {
    description: "Greet a person by name"

    input {
      name: String
    }

    output {
      greeting: String
    }

    implement {
      Ok({ greeting: hello(name) })
    }
  }

  -- Tests live with the code they exercise.
  test "hello returns greeting" {
    assert hello("World") == "Hello, World!"
  }
}
```

## Compile

```bash
skein compile src/main.skein
# → Compiled: Skein.User.HelloWorld
```

## Build the Whole Project

```bash
skein build
```

This compiles every `.skein` file in `src/`.

## Run Tests

```bash
skein test
```

Compiles and loads everything in `src/` and `test/` first, then runs every
`test` block found — co-located tests in `src/` and integration tests in
`test/` alike. On a fresh scaffold that's two tests: the module's own
`test` block and the cross-module `tool.call` test.

## Start a Server

If your project has HTTP, queue, or schedule handlers:

```bash
skein run
```

The command compiles the project, starts the service on port 4000 by
default (change with `--port`), and stays in the foreground while it runs.

## Inspect Traces

Every effect (LLM calls, HTTP requests, store operations) is automatically traced:

```bash
skein trace --last 5
skein trace --kind llm
```

## All Commands

```bash
skein help
```

```
Skein 0.3.0 — AI-native language for the BEAM

Usage: skein <command> [options]

Commands:
  compile <file.skein>       Compile a single .skein file
  new <project-dir>          Scaffold a new Skein project
  build [project-dir]        Compile all .skein files in a project (default: .)
  test [project-dir]         Run all tests in a project (default: .)
  run [project-dir]          Start the Skein service (default: .)
  agents [project-dir]       Create or refresh AGENTS.md (default: .)
  mcp                        Start the MCP server (stdio, for coding agents)
  lsp                        Start the language server (stdio, for editors)
  trace [options]            View recent trace spans
  completions zsh            Print the zsh completion script
  version                    Print version
  help                       Show this help

Options:
  new --backend <name>       LLM backend in skein.toml: anthropic (default),
                             bedrock, openai_compatible, test
  new --no-agents            Skip generating AGENTS.md / CLAUDE.md
  new --no-git               Skip git init (a .gitignore is always written)
  build --output <dir>       Write .beam files to directory
  run --port <port>          Server port (default: 4000)
  trace --last <n>           Number of traces (default: 10)
  trace --kind <kind>        Filter by span kind
```

## Building from Source

If you want to hack on the compiler itself:

```bash
git clone https://github.com/kormie/Skein.git
cd Skein

# mise reads .mise.toml for the right Erlang/Elixir versions
mise install

mise exec -- mix deps.get
mise exec -- mix compile
mise exec -- mix test
```

The project is an Elixir umbrella with four apps:

```
apps/
  skein_compiler/    # Lexer, parser, analyzer, code generator
  skein_runtime/     # Agents, HTTP, store, memory, LLM, tracing
  skein_cli/         # CLI tooling (new, build, test, run, trace, agents, mcp, ...)
  skein_lsp/         # Language Server Protocol implementation
```

## Next Steps

- [Language Guide](/Skein/language/syntax/) — every construct explained
- [Overview](/Skein/getting-started/overview/) — full feature inventory
- [Editor Support](/Skein/editor/vscode/) — VS Code extension with LSP
