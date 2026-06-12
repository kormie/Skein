---
title: Expressions
description: All expression types in Skein and how they compile to BEAM code.
---

## Expression-Oriented Language

Skein is expression-oriented -- everything produces a value. The last expression in a block is its return value. There is no `return` keyword.

```skein
fn abs_value(n: Int) -> Int {
  match n > 0 {
    true  -> n
    false -> 0 - n
  }
}
```

## Literals

### Integers

```skein
42
0
-7
1000
```

Compile to Erlang integers via `:cerl.abstract/1`.

### Booleans

```skein
true
false
```

Compile to Erlang atoms `true` and `false`.

### Strings

Plain strings:

```skein
"hello world"
```

Strings with interpolation:

```skein
"Hello, ${name}!"
"id: ${user.id}"
```

Interpolation accepts an identifier with optional dot access (`${name}`,
`${user.id}`) — not arbitrary expressions. To interpolate a computed value,
bind it first:

```skein
let result = a + b
"Result: ${result}"
```

String interpolation compiles to `erlang:iolist_to_binary/1` over an iolist. For example, `"Hello, ${name}!"` compiles to:

```erlang
call 'erlang':'iolist_to_binary'([<<"Hello, ">>, Name, <<"!">>])
```

This approach handles mixed literal and dynamic segments efficiently.

## Binary Operations

All binary operations compile to Core Erlang calls to the corresponding Erlang BIF:

| Skein | Core Erlang |
|-------|-------------|
| `a + b` | `call 'erlang':'+'(A, B)` |
| `a - b` | `call 'erlang':'-'(A, B)` |
| `a * b` | `call 'erlang':'*'(A, B)` |
| `a / b` | runtime dispatch: `'erlang':'/'` if either operand is a float, else `'erlang':'div'` |
| `a == b` | `call 'erlang':'=='(A, B)` |
| `a != b` | `call 'erlang':'/='(A, B)` |
| `a < b` | `call 'erlang':'<'(A, B)` |
| `a > b` | `call 'erlang':'>'(A, B)` |
| `a <= b` | `call 'erlang':'=<'(A, B)` |
| `a >= b` | `call 'erlang':'>='(A, B)` |
| `a && b` | `call 'erlang':'and'(A, B)` |
| `a \|\| b` | `call 'erlang':'or'(A, B)` |

Note the Erlang-specific mappings: `!=` becomes `'/='` and `<=` becomes `'=<'`. Division compiles to a runtime dispatch — float operands use Erlang `'/'` (float division), integer operands use `'div'` (integer division).

## Let Bindings

Let bindings compile to Core Erlang `let` expressions:

```skein
let doubled = x + x
doubled * 3
```

Becomes:

```erlang
let <Doubled> = call 'erlang':'+'(X, X)
in call 'erlang':'*'(Doubled, 3)
```

## Match Expressions

Match compiles to Core Erlang `case` expressions:

```skein
match n > 0 {
  true  -> "positive"
  false -> "non-positive"
}
```

Becomes:

```erlang
case call 'erlang':'>'(N, 0) of
  <'true'> when 'true' -> <<"positive">>
  <'false'> when 'true' -> <<"non-positive">>
end
```

Match arms can have:
- **Boolean patterns:** `true`, `false`
- **Integer patterns:** `0`, `42`
- **String patterns:** `"active"`, `"paused"`
- **Variable patterns:** `x` (binds the matched value)
- **Wildcard pattern:** `_` (matches anything, discards value)
- **Enum variant patterns:** `Active`, `Status.Active` (matches atom variants)
- **Enum variant with fields:** `Event.Charge(amt)` (destructures into bound variables)

### Enum Variant Patterns

Enum variants can be pattern matched with optional field destructuring:

```skein
enum Result {
  Ok(value: Int)
  Err(message: String)
}

fn unwrap_or(r: Result, default: Int) -> Int {
  match r {
    Result.Ok(v) -> v
    Result.Err(msg) -> default
  }
}
```

Simple variants without fields match as atoms:

```skein
enum Status {
  Active
  Inactive
}

fn is_active(s: Status) -> Bool {
  match s {
    Active -> true
    _ -> false
  }
}
```

Variant patterns compile to Core Erlang tuple patterns. For example, `Result.Ok(v)` becomes a pattern matching the tuple `{:ok, V}`.

### Guards

A match arm may carry a guard: the arm is selected only when the pattern
matches *and* the guard evaluates to `true`. A failing guard falls through to
the later arms.

```skein
match order.total {
  t if t > 1000 -> "review"
  t if t > 0    -> "approve"
  _             -> "reject"
}
```

Guards see the pattern's bindings and must be `Bool`. They are restricted to a
guard-safe subset — literals, bindings, field access, comparisons, boolean
operators, and `+`/`-`/`*` arithmetic. Calls, effects, division, and string
interpolation in a guard are compile errors (`E0027`); compute those values in
a `let` before the match. A guarded arm does not count toward exhaustiveness,
and a `match` where every arm's guard fails raises `case_clause` at runtime.

See [Types > Enum Variant Matching](/Skein/language/types/#enum-variant-matching) for details on exhaustiveness checking.

## Function Calls

Local function calls compile to Core Erlang `apply`:

```skein
add(3, 4)
```

Becomes:

```erlang
apply 'add'/2(3, 4)
```

### Named Arguments

Arguments can be passed by name, in any order, after any positional arguments:

```skein
fn describe(name: String, count: Int) -> String { "${name}" }

describe(count: 3, name: "widget")   -- all named, reordered freely
describe("widget", count: 3)         -- positional first, then named
```

Named arguments work for calls to functions in the same module or agent, and
for effect calls with documented signatures (`llm.chat(model:, system:, input:)`,
`memory.put(key:, value:)`, `http.post(url:, json:)`, and so on).

The analyzer resolves names against the callee's declared parameter names and
rewrites the call into positional order at compile time, so there is no runtime
cost — codegen only ever sees positional arguments. These are compile errors
(`E0026`, with a `fix_hint` listing the valid names):

- An unknown or duplicate argument name
- A positional argument after a named one
- Naming a parameter that was already filled positionally
- Named arguments on a callee without a known signature (e.g. stdlib calls)

Patterns never use named arguments — `Event.Charge(amount: 5)` in a `match`
arm is a parse error.

## Variable Naming Convention

Skein uses `snake_case` for variable names. Core Erlang requires capitalized variable names. The compiler transforms variable names:

| Skein | Core Erlang |
|-------|-------------|
| `x` | `X` |
| `name` | `Name` |
| `my_var` | `MyVar` |
| `ticket_id` | `TicketId` |

The transformation splits on underscores, capitalizes each segment, and joins them.

## Unique Variables

The code generator needs temporary variables for intermediate results (e.g., match subjects). These are generated using a process-local counter:

```elixir
# Generated names: _skein_0, _skein_1, _skein_2, ...
defp gen_var do
  counter = Process.get(:skein_var_counter, 0)
  Process.put(:skein_var_counter, counter + 1)
  String.to_atom("_skein_#{counter}")
end
```

These variables are invisible to the Skein programmer.
