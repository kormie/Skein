---
title: Syntax Overview
description: The current Skein syntax -- what's implemented and how it works.
---

## Universal Pattern

Every Skein construct follows the same structural pattern:

```
<keyword> <name> <signature>? <block>
```

This regularity is a deliberate design choice for agent-writability -- an LLM that learns the pattern once can generate any construct.

## Modules

Modules are the top-level organizational unit. Every Skein file contains a single module:

```
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
```

Module names must start with an uppercase letter (`[A-Z][a-zA-Z0-9]*`).

## Functions

Functions use `fn`. They are always named (no anonymous lambdas). Parameters have explicit types, and a return type is required.

```
fn calculate(a: Int, b: Int) -> Int {
  let sum = a + b
  sum * 2
}
```

The last expression in the block is the return value. There is no `return` keyword.

Zero-parameter functions omit the parens content:

```
fn get_version() -> String {
  "0.1.0"
}
```

## Let Bindings

All bindings use `let`. Bindings are immutable -- there is no `mut`, `var`, or reassignment.

```
fn example(x: Int) -> Int {
  let doubled = x + x
  let result = doubled * 3
  result
}
```

## Match Expressions

`match` is the **only** conditional construct in Skein. No `if/else`, no ternary, no `cond`.

```
fn classify(n: Int) -> String {
  match n > 0 {
    true  -> "positive"
    false -> "non-positive"
  }
}
```

Match arms use the `pattern -> expression` syntax. Each arm body can be a single expression or a block:

```
match status {
  "active" -> handle_active()
  "paused" -> {
    let reason = get_reason()
    handle_paused(reason)
  }
}
```

## Pipe Operator

The pipe `|>` threads the result of the left side as the first argument of the right side:

```
fn process(data: String) -> String {
  data |> transform() |> validate() |> format()
}
```

## String Interpolation

Strings use double quotes with `${}` for interpolation:

```
fn greet(name: String) -> String {
  "Hello, ${name}!"
}
```

Plain strings without interpolation are also supported:

```
fn label() -> String {
  "no interpolation here"
}
```

## Comments

Comments use `--` (double dash). There are no block comments.

```
-- This is a comment
fn add(a: Int, b: Int) -> Int {
  a + b  -- inline comment
}
```

## Operators

### Arithmetic
| Operator | Meaning |
|----------|---------|
| `+` | Addition |
| `-` | Subtraction |
| `*` | Multiplication |
| `/` | Division |

### Comparison
| Operator | Meaning |
|----------|---------|
| `==` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `>` | Greater than |
| `<=` | Less than or equal |
| `>=` | Greater than or equal |

### Logical
| Operator | Meaning |
|----------|---------|
| `&&` | Logical AND |
| `\|\|` | Logical OR |
| `!` (prefix) | Logical NOT |

### Postfix
| Operator | Meaning |
|----------|---------|
| `!` (postfix) | Unwrap Result (crash on error) |
| `?` (postfix) | Propagate Result error |

### Precedence (lowest to highest)

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | `\|>` | Left |
| 2 | `\|\|` | Left |
| 3 | `&&` | Left |
| 4 | `==`, `!=` | None |
| 5 | `<`, `>`, `<=`, `>=` | None |
| 6 | `+`, `-` | Left |
| 7 | `*`, `/` | Left |
| 8 | `!` (prefix) | Prefix |
| 9 | `!`, `?` (postfix) | Postfix |
| 10 | `.` (field access) | Left |
| 11 | Function call `f(x)` | -- |

## Function Calls and Field Access

```
-- Function call
let result = compute(x, y)

-- Field access
let name = user.name

-- Chained
let city = user.address.city

-- Function reference (for higher-order use)
let ref = &my_function
```

## Blocks

Blocks use braces. Always. No significant whitespace, no optional braces.

```
{
  let x = compute(y)
  x + 1
}
```

The last expression in a block is its return value.

## Constructs Parsed but Not Yet Compiled

The parser recognizes these constructs (they produce valid AST nodes), but the code generator does not yet compile them:

- `type Name { field: Type }` -- record type declarations
- `enum Name { Variant1, Variant2 }` -- enum declarations
- `capability kind(params)` -- capability declarations
- `handler`, `agent`, `tool`, `supervisor`, `test` -- future phase constructs
