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

The `assert` keyword evaluates an expression and raises a `RuntimeError` if the result is not `true`:

```skein
assert add(2, 3) == 5     -- passes: 2 + 3 == 5 is true
assert add(2, 3) == 99    -- fails: raises RuntimeError("Assertion failed")
```

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
#=> :ok  (or raises RuntimeError)
```

## Running Tests

### Single File

```bash
# Compile and run tests in one .skein file
mix skein.compile path/to/module.skein
```

### Project-Wide

```bash
# Discover and run all tests across src/ and test/ directories
mix skein.test my_project
```

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
  capability http.out("api.example.com")

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

## Future: Scenario and Golden Tests

The language spec defines two additional test forms that are planned for future implementation:

**Scenario tests** with `given`/`expect` blocks for structured BDD-style testing:

```skein
scenario "refund approval flow" {
  given {
    ticket_id: "T-001"
    amount: 5000
  }
  expect {
    assert decision.action == "approve"
    assert decision.amount == 5000
  }
}
```

**Golden tests** for trace replay:

```skein
golden "recorded refund flow" from trace "traces/refund_001.json" {
  assert final_state.phase == "Done"
}
```
