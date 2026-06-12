---
title: Testing
description: Built-in test constructs in the Skein language for inline testing of modules.
---

## Overview

Skein has built-in test declarations that live alongside the code they test. Tests are compiled into the module as executable functions and can be run via the CLI.

## Test Declarations

Use the `test` keyword inside a module to declare a test:

```skein
module Math {
  fn add(a: Int, b: Int) -> Int { a + b }
  fn double(x: Int) -> Int { x * 2 }

  test "add returns correct sum" {
    assert add(2, 3) == 5
    assert add(0, 0) == 0
    assert add(-1, 1) == 0
  }

  test "double works" {
    assert double(1) == 2
    assert double(0) == 0
  }
}
```

### Syntax

```
test "<description>" {
  <body>
}
```

The body can contain any expression, including `let` bindings, `match` expressions, function calls, and `assert` statements.

## Assert

The `assert` keyword evaluates an expression and raises a structured `Skein.Runtime.AssertionError` if the result is not `true`:

```skein
assert add(2, 3) == 5     -- passes: 2 + 3 == 5 is true
assert add(2, 3) == 99    -- fails: raises Skein.Runtime.AssertionError
```

The error carries the comparison operator and both operand values (`op`, `left`, `right`), the rendered source expression (`expr`), and the assert's source location (`file`, `line`) — so failures report expected vs actual instead of a bare "Assertion failed".

Assert works with any expression that returns a boolean:

```skein
test "comparison operators" {
  assert 5 > 3
  assert 1 == 1
  assert 10 != 5
}
```

## How Tests Compile

Each `test` declaration compiles to:

1. A **test function** `__test_N__/0` that executes the body and returns `:ok` on success (or raises on assertion failure)
2. An entry in the **test metadata** function `__tests__/0`

```elixir
mod.__tests__()
#=> [
#   %{description: "add returns correct sum", fn: :__test_0__},
#   %{description: "double works", fn: :__test_1__}
# ]

mod.__test_0__()
#=> :ok  (or raises Skein.Runtime.AssertionError)
```

## Running Tests

### Project-Wide

```bash
# Discover and run all tests across src/ and test/ directories
skein test my_project

# Or via Mix:
mix skein.test my_project
```

(`mix skein.compile` only compiles a file — it never runs tests.)

The test runner:
1. Walks `test/` and `src/` directories for `.skein` files
2. Compiles each file (skipping files with compile errors)
3. Discovers test declarations via `__tests__/0`
4. Runs each test function and reports aggregate results

```
Running 5 tests across 3 files...
  PASS  add returns correct sum
  PASS  double works
  PASS  greet returns greeting
  FAIL  wrong assertion
  PASS  classify positive

4 passed, 1 failed, 0 compile errors
```

### Programmatically

```elixir
# Single file
{:ok, mod} = Skein.CLI.compile(["path/to/module.skein"])
{:ok, results} = Skein.CLI.test(["path/to/module.skein"])

results.total   #=> 2
results.passed  #=> 2
results.failed  #=> 0

# Project-wide
{:ok, results} = Skein.CLI.test_all(["my_project"])

results.total           #=> 5
results.passed          #=> 4
results.failed          #=> 1
results.files           #=> 3
results.compile_errors  #=> 0
```

## Tests Coexist with Code

Tests are regular module declarations. They can be mixed freely with functions, types, capabilities, and handlers:

```skein
module UserService {
  type User {
    name: String
    email: Email
  }

  fn format_name(first: String, last: String) -> String {
    "${first} ${last}"
  }

  test "format_name joins names" {
    assert format_name("Jane", "Doe") == "Jane Doe"
  }
}
```

## Scenario Tests

Scenario tests provide structured BDD-style testing with explicit `given`/`expect` blocks. The `given` block establishes variable bindings, and the `expect` block contains assertions that run with those bindings in scope.

### Syntax

```
scenario "<description>" {
  given {
    <name>: <expr>
    ...
  }
  expect {
    assert <expr>
    ...
  }
}
```

### Example

```skein
module RefundService {
  fn calculate_refund(amount: Int, rate: Int) -> Int {
    amount * rate
  }

  scenario "high-value refund calculation" {
    given {
      amount: 50000
      rate: 2
    }

    expect {
      assert calculate_refund(amount, rate) == 100000
      assert amount > 10000
    }
  }
}
```

The `given` variables (`amount`, `rate`) are accessible in the `expect` block. The scenario compiles to a test function just like `test` — it appears in `__tests__/0` with `kind: :scenario`.

### When to Use Scenarios

- Testing with explicit, named inputs for readability
- BDD-style specifications where setup and assertions are cleanly separated
- Agent behavior testing with structured initial state

## Golden Tests

Golden tests load a recorded trace file and run assertions against it. They are used for regression testing — recording a known-good execution and verifying it still produces the expected outcomes.

### Syntax

```
golden "<description>" from trace "<path>" {
  assert <expr>
  ...
}
```

### Example

```skein
module ApiTests {
  fn ok() -> Bool { true }

  golden "refund flow trace" from trace "traces/refund_001.json" {
    assert ok()
  }
}
```

The trace file must be a JSON array of span objects. At test execution time, the trace is loaded via `Skein.Runtime.Replay.load_trace/1` before the body runs.

Golden tests appear in `__tests__/0` with `kind: :golden`.

### Trace File Format

Trace files contain event objects from the unified event store (`Skein.Runtime.EventStore`). Each event has at minimum a `kind` field:

```json
[
  {"kind": "effect", "method": "get", "url": "https://api.example.com/refund", "status": 200},
  {"kind": "annotation", "key": "decision", "value": "approved"},
  {"kind": "state_change", "namespace": "sessions", "operation": "put", "key": "decision", "value": "approved"},
  {"kind": "user_event", "event": "refund.approved", "data": {"amount": 100}}
]
```

Supported event kinds: `effect`, `state_change`, `user_event`, `annotation`. Legacy span kinds (`handler`, `llm`, `memory`, `http`) are still accepted for traces recorded before the unified event store.

## Test Kind Field

All three test forms (`test`, `scenario`, `golden`) compile to `__test_N__/0` functions and appear in `__tests__/0` metadata. Each entry includes a `:kind` field:

```elixir
mod.__tests__()
#=> [
#   %{description: "unit test", fn: :__test_0__, kind: :test},
#   %{description: "scenario", fn: :__test_1__, kind: :scenario},
#   %{description: "trace check", fn: :__test_2__, kind: :golden}
# ]
```

The CLI test runner uses this field to report which type of test passed or failed.
