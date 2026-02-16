---
title: Quickstart
description: Build and run your first Skein program in under 5 minutes.
---

## Prerequisites

- **Git**
- **[mise](https://mise.jdx.dev/)** for version management (recommended) — or manually install Erlang/OTP 28+ and Elixir 1.19+

## Setup

```bash
git clone https://github.com/kormie/Skein.git
cd Skein

# mise reads .mise.toml and installs the right Erlang + Elixir versions
mise install

mise exec -- mix deps.get
mise exec -- mix compile
```

The project is an Elixir umbrella with three apps:

```
apps/
  skein_compiler/    # Lexer, parser, analyzer, code generator
  skein_runtime/     # Agents, HTTP, store, memory, LLM, tracing
  skein_cli/         # CLI tooling (new, build, test, run, trace)
```

## Write Your First Program

Create a file called `hello.skein`:

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

## Compile and Run

```bash
mise exec -- mix run -e '
  {:module, mod} = Skein.Compiler.compile_file("examples/hello.skein")
  IO.puts(mod.greet("World"))    # "Hello, World!"
  IO.puts(mod.add(3, 4))         # 7
  IO.puts(mod.classify(-1))      # "non-positive"
'
```

Or compile from a string:

```bash
mise exec -- mix run -e '
  {:module, mod} = Skein.Compiler.compile_string(~S"""
  module Math {
    fn double(x: Int) -> Int { x + x }
  }
  """)
  IO.puts(mod.double(21))  # 42
'
```

## Run with a Real LLM

Skein includes a production Anthropic backend. To see it in action:

```bash
ANTHROPIC_API_KEY=sk-ant-... mise exec -- mix run examples/demo.exs
```

This compiles a Skein module that declares `capability model("anthropic", "claude-sonnet-4-20250514")`, makes real API calls to Claude, and shows the trace output with token usage:

```
🤖 Calling llm.chat via Skein...

📞 mod.greet("World")
   → Hello there, World — welcome to the wonderful world of Skein!

📞 mod.classify("I love this new programming language!")
   → positive

📊 Trace spans:
   • llm:chat claude-sonnet-4-20250514 (1.2s) ✅
     tokens: 28 in → 15 out
```

Every call is capability-gated, type-checked, and automatically traced.

## Run the Tests

```bash
mise exec -- mix test
```

1,280 tests + 182 property-based tests, 0 failures.

## Create a New Project

```bash
mise exec -- mix skein.new my_service
cd my_service
```

This scaffolds a project with `skein.toml`, `src/main.skein`, and `test/main_test.skein`.

## Next Steps

- [Language Guide](/Skein/language/syntax/) — all 12 constructs explained
- [Overview](/Skein/getting-started/overview/) — full feature inventory
- [Editor Support](/Skein/editor/vscode/) — VS Code extension with LSP
