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

```skein
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
```

Module names must start with an uppercase letter (`[A-Z][a-zA-Z0-9]*`).

## Functions

Functions use `fn`. They are always named (no anonymous lambdas). Parameters have explicit types, and a return type is required.

```skein
fn calculate(a: Int, b: Int) -> Int {
  let sum = a + b
  sum * 2
}
```

The last expression in the block is the return value. There is no `return` keyword.

Zero-parameter functions omit the parens content:

```skein
fn get_version() -> String {
  "0.1.0"
}
```

## Let Bindings

All bindings use `let`. Bindings are immutable -- there is no `mut`, `var`, or reassignment.

```skein
fn example(x: Int) -> Int {
  let doubled = x + x
  let result = doubled * 3
  result
}
```

## Match Expressions

`match` is the **only** conditional construct in Skein. No `if/else`, no ternary, no `cond`.

```skein
fn classify(n: Int) -> String {
  match n > 0 {
    true  -> "positive"
    false -> "non-positive"
  }
}
```

Match arms use the `pattern -> expression` syntax. Each arm body can be a single expression or a block:

```skein
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

```skein
fn process(data: String) -> String {
  data |> transform() |> validate() |> format()
}
```

## String Interpolation

Strings use double quotes with `${}` for interpolation:

```skein
fn greet(name: String) -> String {
  "Hello, ${name}!"
}
```

Plain strings without interpolation are also supported:

```skein
fn label() -> String {
  "no interpolation here"
}
```

## Comments

Comments use `--` (double dash). There are no block comments.

```skein
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
| `-` (prefix) | Negation (`-3`, `-x`) |

There is no negative-literal token: negative numbers are written with prefix
`-`, which requires an `Int` or `Float` operand and preserves its type.

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
| 8 | `!`, `-` (prefix) | Prefix |
| 9 | `!`, `?` (postfix) | Postfix |
| 10 | `.` (field access) | Left |
| 11 | Function call `f(x)` | -- |

## Function Calls and Field Access

```skein
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

```skein
{
  let x = compute(y)
  x + 1
}
```

The last expression in a block is its return value.

## Agents

Agents are state machines with phases, transitions, and event-driven handlers:

```skein
agent RefundBot {
  capability memory.kv("sessions")
  capability model("claude-opus-4-8")

  enum Phase {
    Review -> Approved, Denied
    Approved -> Done
    Denied -> Done
    Done
  }

  state {
    request_id: String
    amount: Int
  }

  on start(params) {
    state.request_id = params.id
    state.amount = params.amount
    transition(Review)
  }

  on phase(Review) {
    let decision = llm.chat("claude-opus-4-8", "Evaluate this refund", state.amount)
    match decision {
      "approve" -> transition(Approved)
      "deny" -> transition(Denied)
    }
  }

  on phase(Approved) {
    emit({ type: "refund_approved", amount: state.amount })
    transition(Done)
  }
}
```

Key features:
- `Phase` enum with `->` transition declarations -- validated at compile time
- `on start(params)` handler runs when the agent starts
- `on phase(Phase)` handlers run when entering each phase
- `transition(Phase)` moves to a new phase (invalid transitions are compiler errors)
- `state.field` for reading/writing agent state
- `emit(event)` for domain events
- `stop()` to terminate the agent

## Implementation Status

Most Skein constructs are fully compiled end-to-end. The following notes clarify the status of specific features:

### Fully Compiled

- `tool` declarations -- tool metadata (name, description, input/output schemas) is compiled and available at runtime via `__tools__/0`. See [Tools](/Skein/language/tools/) for details.
- `test`, `scenario`, `golden` -- all three test constructs compile to executable `__test_N__/0` functions with `__tests__/0` metadata. See [Testing](/Skein/language/testing/) for details.

### Also Compiled

- `supervisor` declarations -- agent pool management with child processes, restart strategies, and crash recovery. See [Supervisors](/Skein/language/supervisors/) for details.
- Enum variant pattern matching -- `match` on enum variants with field destructuring compiles to BEAM tuple patterns. See [Types > Enum Variant Matching](/Skein/language/types/#enum-variant-matching).
