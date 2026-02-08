---
title: Modules and Functions
description: How Skein modules and functions work, and how they compile to BEAM modules.
---

## Module Declaration

A Skein file contains a single module declaration:

```skein
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
```

## Module Naming and Elixir Interop

Skein modules compile to BEAM modules with Elixir-compatible names:

| Skein Name | BEAM Module Name |
|------------|-----------------|
| `Hello` | `Elixir.Skein.User.Hello` |
| `UserService` | `Elixir.Skein.User.UserService` |
| `Math` | `Elixir.Skein.User.Math` |

The `Elixir.Skein.User.` prefix:
- Prevents naming collisions with Elixir/Erlang standard modules
- Enables natural Elixir interop: `Skein.User.Hello.greet("World")`
- Follows Elixir's `Elixir.` prefix convention for BEAM module atoms

## `__info__/1` for Elixir Compatibility

Every compiled module includes an `__info__/1` function that makes it behave like an Elixir module:

```elixir
mod.__info__(:module)     #=> Elixir.Skein.User.Hello
mod.__info__(:functions)  #=> [greet: 1, add: 2, classify: 1]
```

This is generated automatically by the code generator. It supports the `:module` and `:functions` queries that Elixir tooling expects.

## Function Declarations

Functions require:
- A name (lowercase identifier)
- Typed parameters (may be empty)
- A return type
- A body block

```skein
fn add(a: Int, b: Int) -> Int {
  a + b
}

fn get_version() -> String {
  "0.1.0"
}
```

### Parameters

Parameters use `name: Type` syntax, separated by commas:

```skein
fn create_user(name: String, email: String, age: Int) -> String {
  "Created ${name}"
}
```

Each parameter compiles to a Core Erlang function variable. The parameter name is transformed from snake_case to CamelCase (e.g., `first_name` becomes `FirstName`).

### Return Type

The return type follows the `->` arrow. It is required on all functions:

```skein
fn compute(x: Int) -> Int { ... }
fn greet(name: String) -> String { ... }
fn is_valid(n: Int) -> Bool { ... }
```

### Body

The function body is always a block (`{ ... }`). The last expression is the return value:

```skein
fn process(x: Int) -> Int {
  let doubled = x * 2      -- intermediate binding
  let adjusted = doubled + 1
  adjusted                   -- this is the return value
}
```

## Multi-Function Modules

Modules typically contain multiple functions:

```skein
module Calculator {
  fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn subtract(a: Int, b: Int) -> Int {
    a - b
  }

  fn multiply(a: Int, b: Int) -> Int {
    a * b
  }

  fn is_positive(n: Int) -> Bool {
    n > 0
  }
}
```

All functions are exported from the compiled BEAM module. There is currently no visibility modifier (all functions are public).

## How Functions Compile

A Skein function:

```skein
fn add(a: Int, b: Int) -> Int {
  a + b
}
```

Compiles to a Core Erlang function definition:

```erlang
'add'/2 = fun (A, B) ->
  call 'erlang':'+'(A, B)
```

The code generator:
1. Creates a Core Erlang function name via `:cerl.c_fname(name_atom, arity)`
2. Creates parameter variables with CamelCase names via `:cerl.c_var/1`
3. Generates the body expression recursively
4. Wraps it all in `:cerl.c_fun/2`
5. Adds the function to the module's export list and definition list

## Compilation Pipeline for a Module

```
Source text
    |
    v
Lexer: tokens = [{:module, {1,1}}, {:upper_ident, {1,8}, "Hello"}, {:lbrace, {1,14}}, ...]
    |
    v
Parser: %AST.Module{name: "Hello", declarations: [%AST.Fn{...}], meta: %{...}}
    |
    v
Analyzer: (pass-through, returns AST unchanged)
    |
    v
CodeGen: :cerl.c_module(...) -> :compile.forms(mod, [:from_core, :binary]) -> beam_binary
    |
    v
Load: :code.load_binary(module_atom, ~c"nofile", beam_binary) -> {:module, module}
```
