---
title: Code Generator
description: How the Skein code generator produces BEAM bytecode via Core Erlang.
---

## Overview

The code generator (`Skein.CodeGen.CoreErlang`) translates the Skein AST into Core Erlang using Erlang's `:cerl` module, then compiles to BEAM bytecode via `:compile.forms/2`.

**Location:** `apps/skein_compiler/lib/skein/codegen/core_erlang.ex` — the largest compiler stage alongside the parser

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
    {:ok, _, beam_binary} -> {:ok, [{module_atom, beam_binary}]}
    {:ok, _, beam_binary, _warnings} -> {:ok, [{module_atom, beam_binary}]}
    {:error, errors, _warnings} -> {:error, format_errors(errors)}
  end
end
```

`generate/1` returns a list of **named binaries** — `{:ok, [{module, binary()}]}` —
because one source file can produce several BEAM modules: a module with nested
agents yields the module itself (`Skein.User.Foo`) followed by one entry per
agent (`Skein.Agent.Foo.Bar`). Nested agents are generated with the module's
capabilities and type declarations in scope, so `llm.json[T]` schema
resolution works inside agent handlers. The compiler driver loads every entry
and returns the first (primary) module.

## Function Generation

Each Skein function becomes a Core Erlang function:

```skein
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

Binary ops compile to `erlang` BIF calls (division is special-cased; see the footnote below):

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
| `/` | `:div` / `:/` (runtime dispatch)* |
| `==` | `:==` |
| `!=` | `:"/="` |
| `<` | `:<` |
| `>` | `:>` |
| `<=` | `:"=<"` |
| `>=` | `:>=` |
| `&&` | `:and` |
| `\|\|` | `:or` |

\* Division does not compile to a single BIF call. The generator binds both operands, then emits a `case` on `erlang:is_float/1` of either operand: if either is a float, it calls `erlang:'/'` (float division); otherwise it calls `erlang:div` (integer division). So `7 / 2` is `3` while `7.0 / 2` is `3.5`.

### Let Bindings

```skein
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

```skein
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

```skein
{
  let x = a + b
  let y = x * 2
  y
}
```

The last expression becomes the body of the innermost `let`.

## Enum Variant Construction

Variant constructors lower to the same shapes the pattern side matches:

| Skein expression | Core Erlang value |
|------------------|-------------------|
| `Status.Active`, bare `Active`, `Status.Active()` | `:active` (bare atom) |
| `Status.Banned("spam")`, bare `Banned("spam")` | `{:banned, "spam"}` |
| `Ok(x)` / `Err(e)` | `{:ok, X}` / `{:error, E}` |
| `SearchError.from(e)` | `{:search_error, E}` |

Zero-field variants are **bare atoms**, not 1-tuples, so constructions
round-trip through `match` arms (`Active -> ...` compiles to the atom
pattern `:active`). Variant names are snake_cased (`ChargeSucceeded` ->
`:charge_succeeded`).

The analyzer validates constructions before codegen runs: unknown variants
(E0010, with a closest-name `fix_code`), wrong arity, wrong argument types,
and a data variant referenced without arguments (E0020, with a
`Enum.Variant(fields)` skeleton) are all structured compile errors — never
`core_lint` crashes.

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

## Stdlib Call Generation

When the code generator encounters a call to a known stdlib module like `String.upcase(s)`, it generates a remote call to the corresponding runtime module:

```skein
-- Skein source:
String.upcase(name)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Stdlib.String':'upcase'(Name)
```

The mapping from Skein module names to Elixir runtime modules:

| Skein Module | Runtime Module |
|-------------|---------------|
| `String` | `Skein.Runtime.Stdlib.String` |
| `Int` | `Skein.Runtime.Stdlib.Int` |
| `Float` | `Skein.Runtime.Stdlib.Float` |
| `List` | `Skein.Runtime.Stdlib.List` |
| `Map` | `Skein.Runtime.Stdlib.Map` |
| `Set` | `Skein.Runtime.Stdlib.Set` |
| `Option` | `Skein.Runtime.Stdlib.Option` |
| `Result` | `Skein.Runtime.Stdlib.Result` |
| `Uuid` | `Skein.Runtime.Stdlib.Uuid` |
| `Instant` | `Skein.Runtime.Stdlib.Instant` |
| `Duration` | `Skein.Runtime.Stdlib.Duration` |

No capabilities are required for stdlib calls. See the [Standard Library reference](/Skein/reference/stdlib/) for the full API.

## Effect Call Generation

When the code generator encounters an effect call like `http.get(url)`, it generates a remote call to the runtime instead of a local apply:

```skein
-- Skein source:
http.get(url)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Http':'get'(Url, Capabilities)
```

The generator recognizes effect calls by pattern-matching on `Call{target: FieldAccess{subject: Identifier{name}, field}}` where `name` is a known effect namespace.

### Capabilities parameter

Every effect call appends the module's compiled capabilities list as the final argument. This is built at compile time from the module's `capability` declarations and enables runtime enforcement:

```skein
-- Skein source (module has: capability http.out("api.example.com"))
http.get(url)

-- Compiles to:
call 'Elixir.Skein.Runtime.Http':'get'(
  Url,
  [#{kind => "http.out", params => ["api.example.com"]}]
)
```

### Effect namespace to runtime module mapping

| Namespace | Runtime Module | Operations |
|-----------|---------------|------------|
| `http` | `Skein.Runtime.Http` | `get`, `post`, `put`, `patch`, `delete` |
| `store.<table>` | `Skein.Runtime.Store` | `get`, `put`, `delete`, `query` |
| `memory` | `Skein.Runtime.Memory` | `put`, `get`, `get!`, `delete`, `list` |
| `llm` | `Skein.Runtime.Llm` | `chat`, `json`, `stream`, `embed` |
| `tool` | `Skein.Runtime.Tool` | `call`, `list`, `schema` |
| `topic` | `Skein.Runtime.Topic` | `publish` |
| `trace` | `Skein.Runtime.Trace` | `annotate` |
| `event` | `Skein.Runtime.EventStore` | `log` |
| `process` | `Skein.Runtime.Process` | `spawn` |
| `timer` | `Skein.Runtime.Timer` | `after`, `interval`, `cancel` |

### HTTP effect compilation

HTTP calls follow the generic pattern -- the namespace maps to `Skein.Runtime.Http` and the method becomes the function name:

```skein
http.post("https://api.example.com/data", body)

-- Compiles to:
call 'Elixir.Skein.Runtime.Http':'post'(Url, Body, Capabilities)
```

### Store effect compilation

Store effects have a three-level namespace: `store.<table>.<operation>`. The code generator extracts the table name and passes it as the first argument:

```skein
store.users.get(id)

-- Compiles to:
call 'Elixir.Skein.Runtime.Store':'get'("users", Id, Capabilities)
```

### Memory effect compilation

Memory effects extract the namespace from the `memory.kv(namespace)` capability declaration and pass it as the first argument:

```skein
-- Module has: capability memory.kv("sessions")
memory.put("user", user_id)

-- Compiles to:
call 'Elixir.Skein.Runtime.Memory':'put'("sessions", "user", UserId, Capabilities)
```

### LLM effect compilation

LLM calls have special handling for each method:

**`llm.chat`** -- standard text response:
```skein
llm.chat("claude-opus-4-8", "System prompt", input)

-- Compiles to:
call 'Elixir.Skein.Runtime.Llm':'chat'("claude-opus-4-8", "System prompt", Input, Capabilities)
```

**`llm.json[T]`** -- schema-constrained JSON. The type parameter is compiled into a JSON Schema literal using `SchemaGen`:
```skein
llm.json[Decision]("claude-opus-4-8", "Decide action", input)

-- Compiles to:
call 'Elixir.Skein.Runtime.Llm':'json'("claude-opus-4-8", "Decide action", Input, Schema, Capabilities)
```

Where `Schema` is the JSON Schema derived from the `Decision` type definition at compile time.

**`llm.stream`** -- streaming response:
```skein
llm.stream("claude-opus-4-8", "Generate report", data)

-- Compiles to:
call 'Elixir.Skein.Runtime.Llm':'stream'("claude-opus-4-8", "Generate report", Data, NoOpCallback, Capabilities)
```

**`llm.embed`** -- embedding vector:
```skein
llm.embed("voyage-3-large", input)

-- Compiles to:
call 'Elixir.Skein.Runtime.Llm':'embed'("voyage-3-large", Input, Capabilities)
```

### Tool effect compilation

Tool calls lower tool identifier references to string literals:

```skein
tool.call(Stripe.CreateRefund, { amount: 100 })

-- Compiles to:
call 'Elixir.Skein.Runtime.Tool':'call'("Stripe.CreateRefund", Args, Capabilities)
```

### Respond compilation

Handler response helpers compile to tagged tuples (not runtime module calls):

```skein
respond.json(200, data)    -- {:respond_json, 200, data}
respond.text(200, body)    -- {:respond_text, 200, body}
respond.html(200, page)    -- {:respond_html, 200, page}
```

### Idempotent compilation

The `idempotent(key)` construct compiles to a runtime check:

```skein
idempotent("process-order-123")

-- Compiles to:
call 'Elixir.Skein.Runtime.Idempotent':'check!'("process-order-123")
```

### Generic effect compilation

Any effect namespace listed in the runtime modules map that doesn't have special handling follows the generic pattern:

```skein
namespace.method(arg1, arg2)

-- Compiles to:
call 'Elixir.Skein.Runtime.<Module>':'method'(Arg1, Arg2, Capabilities)
```

This covers `process.spawn`, `timer.after`, `timer.interval`, `timer.cancel`, `trace.annotate`, `event.log`, and `topic.publish`.

## Handler Generation

Handler declarations compile to regular functions with metadata. Each handler produces:

1. A handler function that takes a request map and returns a response
2. An entry in `__handlers__/0` with the method, route pattern, and parameter names

```skein
-- Skein source:
handler http GET "/users/:id" (req) -> {
  req.params.id
}

-- Generates:
-- 1. A function '__handler_GET_/users/:id'/1
-- 2. Metadata in __handlers__/0: [%{method: "GET", route: "/users/:id", params: ["id"]}]
```

## `__capabilities__/0` Function

Every compiled module includes a `__capabilities__/0` function that returns the module's declared capabilities as a list of maps:

```elixir
Skein.User.MyService.__capabilities__()
#=> [%{kind: "http.out", params: ["api.example.com"]}]
```

A module with no capabilities returns an empty list. Each capability map has:
- `:kind` -- the capability type (e.g., `"http.out"`)
- `:params` -- list of string parameters (e.g., host allowlist)

## Property-Tested Invariants

The code generator's property-based tests verify invariants including:

- Integer addition computes correctly for random inputs
- Integer subtraction computes correctly for random inputs
- Integer multiplication computes correctly for random inputs
- Comparison `>` produces correct booleans
- Equality `==` produces correct booleans
- String interpolation round-trips alphanumeric input
- Let bindings preserve computed values
- Match on `> 0` correctly classifies positive vs non-positive
- Plain string literals return exact strings
