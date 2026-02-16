---
title: Quickstart
description: Build and run your first Skein program in under 5 minutes.
---

## Install

Grab the latest binary for your platform from the [CI builds](https://github.com/kormie/Skein/actions/workflows/build.yml):

| Platform | Artifact |
|---|---|
| Linux x86_64 | `skein-linux-x86_64` |
| Linux ARM64 | `skein-linux-aarch64` |
| macOS x86_64 | `skein-macos-x86_64` |
| macOS ARM64 (Apple Silicon) | `skein-macos-aarch64` |

```bash
# Make it executable and put it on your PATH
chmod +x skein_*
mv skein_* /usr/local/bin/skein

skein version  # → skein 0.1.0
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
  src/main.skein
  test/main_test.skein
```

## Write Your First Program

Edit `src/main.skein`:

```skein
module Hello {
  fn greet(name: String) -> String {
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
}
```

## Compile

```bash
skein compile src/main.skein
# → Compiled: Skein.User.Hello
```

## Build the Whole Project

```bash
skein build .
```

This compiles every `.skein` file in `src/`.

## Run Tests

```bash
skein test .
```

Discovers and runs all test files in `src/` and `test/`.

## Start a Server

If your project has HTTP, queue, or schedule handlers:

```bash
skein run .
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
Skein 0.1.0 — AI-native language for the BEAM

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

The project is an Elixir umbrella with three apps:

```
apps/
  skein_compiler/    # Lexer, parser, analyzer, code generator
  skein_runtime/     # Agents, HTTP, store, memory, LLM, tracing
  skein_cli/         # CLI tooling (new, build, test, run, trace)
```

## Next Steps

- [Language Guide](/Skein/language/syntax/) — all 12 constructs explained
- [Overview](/Skein/getting-started/overview/) — full feature inventory
- [Editor Support](/Skein/editor/vscode/) — VS Code extension with LSP
