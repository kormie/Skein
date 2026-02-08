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
  skein_runtime/     # HTTP client, handler dispatch, store, trace recording
  skein_cli/         # CLI tooling (stub)
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

## Run the Tests

```bash
# Run all tests from the project root
mix test

# Run just the compiler tests
mix test --only app:skein_compiler

# Run with verbose output
mix test --trace
```

The test suite includes:
- **352 unit tests** across lexer, parser, analyzer, codegen, and runtime
- **44 property-based tests** -- randomized inputs across lexer, parser, codegen, capability checking, and store operations

## Compiled Module Naming

Skein modules compile to Elixir-compatible module names following the pattern `Elixir.Skein.User.<Name>`. This means:

- A Skein module named `Hello` becomes `Elixir.Skein.User.Hello`
- You can call it as `Skein.User.Hello.greet("World")` from Elixir
- The compiler returns the module atom directly, so you can use the variable: `mod.greet("World")`

Each compiled module includes an `__info__/1` function for Elixir interop, supporting `:module` and `:functions` queries.
