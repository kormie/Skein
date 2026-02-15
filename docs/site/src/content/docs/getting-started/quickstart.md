---
title: Quickstart
description: Build and run your first Skein program.
---

## Prerequisites

- Elixir 1.19+ on OTP 28+
- Git (for fetching dependencies)

## Setup

Clone the repository and fetch dependencies:

```bash
git clone <repo-url> skein
cd skein
mix deps.get
mix compile
```

The project is an Elixir umbrella with three apps:

```
apps/
  skein_compiler/    # Lexer, parser, analyzer, code generator
  skein_runtime/     # Agents, HTTP client, handler dispatch, store, memory, LLM, trace recording
  skein_cli/         # CLI tooling (new, build, test, run, trace)
```

## Create a New Project

The fastest way to start is with `skein new`:

```bash
mix skein.new my_service
cd my_service
```

This creates:

```
my_service/
  skein.toml           # Project configuration
  README.md
  src/main.skein       # Example module
  test/main_test.skein # Example test
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

From an IEx session:

```bash
cd apps/skein_compiler
iex -S mix
```

```elixir
# Compile from a file
{:module, mod} = Skein.Compiler.compile_file("../../examples/hello.skein")
mod.greet("World")    #=> "Hello, World!"
mod.add(3, 4)         #=> 7
mod.classify(-1)      #=> "non-positive"

# Or compile from a string
{:module, mod} = Skein.Compiler.compile_string(~S"""
module Math {
  fn double(x: Int) -> Int {
    x + x
  }
}
""")
mod.double(21)        #=> 42
```

## Build and Test a Project

```bash
# Build all .skein files in a project
mix skein.build my_service

# Run all Skein tests across src/ and test/ directories
mix skein.test my_service

# Start the service (if it has HTTP handlers)
mix skein.run my_service --port 4000

# View recent traces
mix skein.trace --last 10
```

## Run the Compiler Tests

```bash
# Run all tests from the project root
mix test

# Run just the compiler tests
mix test --only app:skein_compiler

# Run with verbose output
mix test --trace
```

The test suite includes:
- **706+ unit tests** across lexer, parser, analyzer, codegen, runtime, and CLI
- **72 property-based tests** -- randomized inputs across lexer, parser, codegen, capability checking, store, tool operations, and handler types

## Running with a Real LLM Backend

Skein includes a production Anthropic backend for making real LLM calls. To use it:

1. **Set your API key** as an environment variable:

```bash
export ANTHROPIC_API_KEY=sk-ant-api03-...
```

2. **Run the demo script** to see it in action:

```bash
ANTHROPIC_API_KEY=sk-ant-... mix run examples/demo.exs
```

This compiles a Skein module with `llm.chat` calls and makes real requests to Claude.

3. **Configure the backend** in your application config:

```elixir
# config/config.exs
config :skein_runtime, :llm_backend, Skein.Runtime.Llm.AnthropicBackend
config :skein_runtime, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
```

Or set the backend at runtime:

```elixir
Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.AnthropicBackend)
```

### Model Mapping

Any `gpt-*` model name is automatically mapped to `claude-sonnet-4-20250514`. Claude model names are passed through as-is.

### Supported Operations

| Operation | Status |
|-----------|--------|
| `llm.chat(model, system, input)` | ✅ Full support |
| `llm.json(model, system, input)` | ✅ Schema-constrained JSON output |
| `llm.stream(model, system, input)` | ✅ Server-sent events streaming |
| `llm.embed(model, input)` | ❌ Not available (use OpenAI or Voyage AI) |

## Compiled Module Naming

Skein modules compile to Elixir-compatible module names following the pattern `Elixir.Skein.User.<Name>`. This means:

- A Skein module named `Hello` becomes `Elixir.Skein.User.Hello`
- You can call it as `Skein.User.Hello.greet("World")` from Elixir
- The compiler returns the module atom directly, so you can use the variable: `mod.greet("World")`

Each compiled module includes an `__info__/1` function for Elixir interop, supporting `:module` and `:functions` queries.
