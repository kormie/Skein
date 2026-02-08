---
title: Code Generator
description: How the Skein code generator produces BEAM bytecode via Core Erlang.
---

## Overview

The code generator (`Skein.CodeGen.CoreErlang`) translates the Skein AST into Core Erlang using Erlang's `:cerl` module, then compiles to BEAM bytecode via `:compile.forms/2`.

**Location:** `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` (~480 lines)

## What is Core Erlang?

Core Erlang is a simplified, explicit intermediate representation for the BEAM VM. It's what Elixir, LFE, Gleam, and now Skein compile to. Key properties:

- All variables are single-assignment
- All functions are explicitly named with arity
- Pattern matching is lowered to `case` expressions
- No syntactic sugar -- everything is explicit
- The `:cerl` module provides an API for constructing Core Erlang AST nodes programmatically

## The `:cerl` Module

Instead of generating Core Erlang text, the code generator builds AST nodes using `:cerl`:

```elixir
# Create a module
:cerl.c_module(name, exports, attributes, definitions)

# Create a function
:cerl.c_fun(params, body)

# Create a case expression
:cerl.c_case(subject, clauses)

# Create a let binding
:cerl.c_let(vars, value, body)

# Create a function call (to another module)
:cerl.c_call(module, function, args)

# Create a local function application
:cerl.c_apply(function, args)

# Create literals
:cerl.abstract(42)        # integer
:cerl.abstract("hello")   # binary string
:cerl.abstract(true)      # boolean atom

# Create variables
:cerl.c_var(:MyVar)

# Create a list
:cerl.make_list(elements)
```

## Module Generation

A Skein module compiles to a Core Erlang module with:
1. The module name atom (`Elixir.Skein.User.<Name>`)
2. An export list of all functions + `__info__/1`
3. Function definitions
4. An `__info__/1` function for Elixir compatibility

```elixir
def generate(%AST.Module{} = ast) do
  module_atom = String.to_atom("Elixir.Skein.User.#{ast.name}")

  fns = Enum.filter(ast.declarations, &match?(%AST.Fn{}, &1))
  exports = Enum.map(fns, fn f ->
    :cerl.c_fname(String.to_atom(f.name), length(f.params))
  end)

  defs = Enum.map(fns, fn f ->
    fname = :cerl.c_fname(String.to_atom(f.name), length(f.params))
    fun = generate_fn(f)
    {fname, fun}
  end)

  # Add __info__/1
  info_fname = :cerl.c_fname(:__info__, 1)
  info_fun = generate_info_fn(module_atom, fns)

  mod = :cerl.c_module(
    :cerl.c_atom(module_atom),
    [info_fname | exports],
    [],
    [{info_fname, info_fun} | defs]
  )

  case :compile.forms(mod, [:from_core, :binary, :return_errors]) do
    {:ok, _, beam_binary} -> {:ok, beam_binary}
    {:ok, _, beam_binary, _warnings} -> {:ok, beam_binary}
    {:error, errors, _warnings} -> {:error, format_errors(errors)}
  end
end
```

## Function Generation

Each Skein function becomes a Core Erlang function:

```
fn add(a: Int, b: Int) -> Int {
  a + b
}
```

Generates:

```erlang
'add'/2 = fun (A, B) ->
  call 'erlang':'+'(A, B)
```

The generator:
1. Creates parameter variables (snake_case -> CamelCase)
2. Builds a scope map from parameter names to Core Erlang variables
3. Recursively generates the body expression
4. Wraps in `:cerl.c_fun/2`

## Expression Generation

### Literals

| Skein | Core Erlang via :cerl |
|-------|----------------------|
| `42` | `:cerl.abstract(42)` |
| `3.14` | `:cerl.abstract(3.14)` |
| `true` | `:cerl.abstract(true)` |
| `false` | `:cerl.abstract(false)` |
| `"hello"` | `:cerl.abstract("hello")` |

### String Interpolation

`"Hello, ${name}!"` compiles to an iolist passed to `erlang:iolist_to_binary/1`:

```elixir
# Build the iolist: ["Hello, ", Name, "!"]
parts = [
  :cerl.abstract("Hello, "),
  :cerl.c_var(:Name),
  :cerl.abstract("!")
]
iolist = :cerl.make_list(parts)

# Wrap in erlang:iolist_to_binary/1
:cerl.c_call(
  :cerl.c_atom(:erlang),
  :cerl.c_atom(:iolist_to_binary),
  [iolist]
)
```

This approach was chosen over binary construction (`<<>>`) because:
- It handles mixed literal and dynamic segments naturally
- The `:cerl.abstract/1` function produces proper binary literals
- `iolist_to_binary` is efficient and well-understood on the BEAM

### Binary Operations

All binary ops compile to `erlang` BIF calls:

```elixir
# a + b
:cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:+), [left, right])
```

Operator mapping:

| Skein | Erlang BIF |
|-------|-----------|
| `+` | `:+` |
| `-` | `:-` |
| `*` | `:*` |
| `/` | `:div` |
| `==` | `:==` |
| `!=` | `:"/="` |
| `<` | `:<` |
| `>` | `:>` |
| `<=` | `:"=<"` |
| `>=` | `:>=` |
| `&&` | `:and` |
| `\|\|` | `:or` |

### Let Bindings

```
let x = expr
body
```

Compiles to:

```elixir
:cerl.c_let(
  [:cerl.c_var(:X)],        # bound variable
  generate_expr(value),       # value expression
  generate_expr(body)         # body where variable is in scope
)
```

### Match Expressions

```
match subject {
  true  -> "yes"
  false -> "no"
}
```

Compiles to a Core Erlang `case`:

```elixir
:cerl.c_case(
  generate_expr(subject),
  [
    :cerl.c_clause([:cerl.abstract(true)], :cerl.abstract("yes")),
    :cerl.c_clause([:cerl.abstract(false)], :cerl.abstract("no"))
  ]
)
```

### Function Calls

Local function calls use `:cerl.c_apply/2`:

```elixir
:cerl.c_apply(
  :cerl.c_fname(String.to_atom(name), arity),
  args
)
```

### Blocks

Multi-expression blocks use chained `let` bindings. Each expression except the last is bound to a unique temporary variable:

```
{
  let x = a + b
  let y = x * 2
  y
}
```

The last expression becomes the body of the innermost `let`.

## Variable Naming

Skein snake_case variables are converted to Core Erlang CamelCase:

```elixir
defp var_name(name) when is_binary(name) do
  name
  |> String.split("_")
  |> Enum.map(&String.capitalize/1)
  |> Enum.join()
  |> String.to_atom()
end
```

| Skein | Core Erlang |
|-------|------------|
| `x` | `X` |
| `name` | `Name` |
| `my_var` | `MyVar` |
| `ticket_id` | `TicketId` |

## Temporary Variables

The generator needs unique variables for intermediate results. These are created with a process-local counter:

```elixir
defp gen_var do
  counter = Process.get(:skein_var_counter, 0)
  Process.put(:skein_var_counter, counter + 1)
  String.to_atom("_skein_#{counter}")
end
```

## Compilation

The final step compiles the Core Erlang AST to BEAM bytecode:

```elixir
:compile.forms(core_module, [:from_core, :binary, :return_errors])
```

The `:from_core` flag tells the compiler the input is Core Erlang (not Erlang source). The `:binary` flag returns the bytecode as a binary rather than writing to disk. The `:return_errors` flag returns errors as data rather than printing to stderr.

## Property-Tested Invariants

The code generator has 9 property-based tests verifying:

- Integer addition computes correctly for random inputs
- Integer subtraction computes correctly for random inputs
- Integer multiplication computes correctly for random inputs
- Comparison `>` produces correct booleans
- Equality `==` produces correct booleans
- String interpolation round-trips alphanumeric input
- Let bindings preserve computed values
- Match on `> 0` correctly classifies positive vs non-positive
- Plain string literals return exact strings
