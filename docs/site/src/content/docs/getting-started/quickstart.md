---
title: Quickstart
description: Build and run your first Skein program in under 5 minutes.
---

## Install

Grab the latest binary for your platform from the
[Releases page](https://github.com/kormie/Skein/releases):

| Platform | Asset |
|---|---|
| Linux x86_64 | `skein-linux-x86_64` |
| Linux ARM64 | `skein-linux-aarch64` |
| macOS x86_64 | `skein-macos-x86_64` |
| macOS ARM64 (Apple Silicon) | `skein-macos-aarch64` |

```bash
# Make it executable and put it on your PATH
chmod +x skein-*
mv skein-* /usr/local/bin/skein

skein version  # → skein 0.1.2
```

No Erlang, Elixir, or other dependencies required — it's a self-contained binary.

## Create a Project

```bash
skein new hello_world
cd hello_world
```

This gives you:

```
hello_world/
  skein.toml
  src/main.skein        # module + tool + co-located test
  test/main_test.skein  # integration test through the module's tool
```

The scaffold already runs: `src/main.skein` declares a function, a `test`
block next to it, and a tool — the one cross-module seam in Skein — and
`test/main_test.skein` exercises that tool the way another service or
agent would.

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
# → Compiled: Skein.User.Hello
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
# → Server running on port 4000
```

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
Skein 0.1.2 — AI-native language for the BEAM

Commands:
  compile <file.skein>       Compile a single .skein file
  new <project-dir>          Scaffold a new Skein project
  build <project-dir>        Compile all .skein files in a project
  test <project-dir>         Run all tests in a project
  run <project-dir>          Start the Skein service
  trace [options]            View recent trace spans
  version                    Print version
  help                       Show this help
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
  skein_cli/         # CLI tooling (new, build, test, run, trace)
  skein_lsp/         # Language Server Protocol implementation
```

## Next Steps

- [Language Guide](/Skein/language/syntax/) — all 12 constructs explained
- [Overview](/Skein/getting-started/overview/) — full feature inventory
- [Editor Support](/Skein/editor/vscode/) — VS Code extension with LSP
