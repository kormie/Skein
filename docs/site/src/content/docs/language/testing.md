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
Tests: 4 passed, 1 failed (5 total)
  FAIL: wrong assertion (src/math.skein:12) — Assertion failed: expected 5, got 4
```

Passing tests print no per-test lines; failures go to stderr with their
location and error, files that fail to compile are listed as
`N file(s) failed to compile and were not tested:` followed by their
diagnostics, and the exit code is non-zero when anything failed.

### Programmatically

```elixir
# Single file
{:ok, mod, _warnings} = Skein.CLI.compile(["path/to/module.skein"])
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

### Replay Contract for Nondeterministic Effects

Golden replay is not a loose fixture system: it is the contract for every nondeterministic source that agent code can touch. The compiler still threads the declared capability list into each runtime effect call, and the runtime performs the capability check before consuming a recorded event. A golden test therefore proves both that the program declared the effect and that the recorded effect sequence still matches the current code.

Replayable effect events must include enough fields to match the live call and reconstruct the result without contacting an outside system or starting background work:

| Source | Required capability | Replay event fields | Replay behavior |
|---|---|---|---|
| `llm.chat` / `llm.json` / `llm.stream` / `llm.embed` | `model(...)` | `kind: "llm"`, `method`, `model`, `response` | Returns the recorded response; streams deliver the recorded response as replayed chunks. |
| `http.get` / `post` / `put` / `patch` / `delete` | `http.out(...)` | `kind: "http"`, `method`, `url`, `status`, `response_body`, optional `response_headers` | Reconstructs `Result[HttpResponse, HttpError]`; no network request is made. |
| `tool.call` | `tool.use(...)` | `kind: "tool"`, `method: "call"`, `name`, `response` | Returns the recorded tool result; no registered live tool runs. |
| `uuid.new()` | `uuid` | `kind: "uuid"`, `value` | Returns the recorded UUID value. |
| `instant.now()` | `instant` | `kind: "instant"`, `value` | Returns the recorded instant. |
| `process.spawn(...)` | `process.spawn(...)` | `kind: "process"`, `method: "spawn"`, optional `pool`, optional `task`, `result` / `spawn_id` | Returns an inert pid-shaped handle and does not start background work. |
| `timer.after` / `timer.interval` / `timer.cancel` | `timer(...)` | `kind: "timer"`, `method`, `group`, delay/interval/ref fields, `timer_ref` | Returns the recorded timer ref/result and does not arm a live timer during replay. |
| `queue.publish` / `topic.publish` delivery traces | `queue.publish(...)` / `topic.publish(...)` | `kind: "queue"` or `kind: "topic"`, queue/topic name, message/payload fields | Replays the recorded delivery order from EventStore data instead of depending on scheduler timing. |

If a recorded event is exhausted or the next event's matching fields differ from the live call (for example a different model, URL, tool name, timer group, or task name), replay returns a structured error instead of falling through to live I/O. In `skein test`, unrecorded outbound HTTP/LLM/tool effects are blocked unless explicitly allowed by the test runner policy; UUID and clock effects use deterministic test defaults only when no recorded trace is active.

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
