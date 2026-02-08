---
title: Unit Tests
description: How the Skein compiler is tested with ExUnit.
---

## Testing Philosophy

**TDD is mandatory.** Tests are written before or alongside implementation -- never after. Every public function must have tests covering its happy path and error cases.

## Test Organization

```
apps/skein_compiler/test/
  skein/
    lexer_test.exs                    # 69 unit tests
    parser_test.exs                   # 104 unit tests (incl. scenario/golden)
    codegen/
      core_erlang_test.exs            # 36 integration tests
      schema_gen_test.exs             # 22 unit tests
    integration/
      memory_llm_test.exs             # 8 integration tests
      tool_test.exs                   # 14 integration tests
      test_construct_test.exs         # 15 integration tests (incl. scenario/golden)
      req_json_test.exs               # 4 integration tests
    analyzer_test.exs                 # 76 unit tests
apps/skein_runtime/test/
  skein/runtime/
    replay_test.exs                   # 13 tests (Phase 8a)
    ... (186 runtime tests total)
apps/skein_cli/test/
  cli/test_runner_test.exs            # 10 tests (incl. scenario/golden)
  ... (43 CLI tests total)
```

**Total: 664 tests, 70 properties, 0 failures**

## Lexer Tests (69 tests)

The lexer test suite covers:

- **Individual token types:** Each keyword, operator, and literal type has dedicated tests
- **Multi-token sequences:** `let x = 42` produces the expected token list
- **String handling:** Plain strings, interpolation, empty strings, escaped characters
- **Position tracking:** Line and column numbers are correct across multi-line input
- **Comments:** Single-line comments are properly ignored
- **Error cases:** Unrecognized characters produce structured errors

Example:

```elixir
test "tokenizes a simple binding" do
  assert {:ok, tokens} = Skein.Lexer.tokenize("let x = 42")
  assert tokens == [
    {:let, {1, 1}},
    {:ident, {1, 5}, "x"},
    {:eq, {1, 7}},
    {:int, {1, 9}, 42},
    {:eof, {1, 14}}
  ]
end
```

## Parser Tests (47 tests)

The parser test suite covers every AST construct:

- **Module parsing:** Empty modules, modules with functions
- **Function parsing:** With/without parameters, various return types
- **Let bindings:** Simple values, expression values
- **Match expressions:** Boolean matching, pattern types, multiple arms
- **Operator precedence:** All operator combinations at different levels
- **Operator associativity:** Left-associative chaining
- **Pipe expressions:** Single and chained pipes
- **Function calls:** With arguments, nested calls
- **Field access:** Simple and chained field access
- **String handling:** Plain strings, interpolation
- **Literals:** Integers, floats, booleans
- **Unary operators:** Prefix `!`, postfix `!` and `?`
- **Type declarations:** Record types with typed fields
- **Enum declarations:** Simple variants and variants with data
- **Capability declarations:** With parameters
- **Parenthesized expressions:** Grouping for precedence override
- **Function references:** `&name` syntax
- **Complete examples:** The full `hello.skein` program
- **Error cases:** Missing tokens, unexpected tokens

Example:

```elixir
test "parses binary operator with correct precedence" do
  source = "module M { fn f(a: Int, b: Int, c: Int) -> Int { a + b * c } }"
  {:ok, tokens} = Lexer.tokenize(source)
  {:ok, %AST.Module{declarations: [f]}} = Parser.parse(tokens)

  assert %AST.Block{expressions: [expr]} = f.body
  assert %AST.BinaryOp{op: :+} = expr
  assert %AST.BinaryOp{op: :*} = expr.right
end
```

## CodeGen Integration Tests (18 tests)

These are **full pipeline tests** -- they compile Skein source to BEAM bytecode, load the module, and call its functions:

- **Phase 1 acceptance tests:** `greet/1`, `add/2`, `classify/1` from `hello.skein`
- **Arithmetic operations:** Addition, subtraction, multiplication
- **Let bindings:** Binding preservation, sequential bindings
- **Boolean operations:** Comparison operators, equality
- **String operations:** Plain strings, string interpolation, multi-segment interpolation
- **Match expressions:** Boolean matching with true/false arms
- **File compilation:** `compile_file/1` with the example file
- **Elixir interop:** `__info__(:module)`, `__info__(:functions)`

Example:

```elixir
test "Phase 1 acceptance: greet/1 returns interpolated greeting" do
  source = ~S"""
  module Greeter {
    fn greet(name: String) -> String {
      "Hello, ${name}!"
    }
  }
  """
  {:module, mod} = Compiler.compile_string(source)
  assert mod.greet("World") == "Hello, World!"
  assert mod.greet("Skein") == "Hello, Skein!"
end
```

## Important Test Conventions

### Async Settings

CodeGen tests use `async: false` because they load BEAM modules into the VM -- a global, shared resource:

```elixir
use ExUnit.Case, async: false
```

Lexer and parser tests use `async: true` since they are pure functions with no side effects.

### String Escaping

Use the `~S` sigil for Skein source strings in tests to avoid Elixir interpolation conflicts:

```elixir
# Good: ~S prevents Elixir from interpreting ${name}
source = ~S"""
module M {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
"""

# Bad: Elixir would try to interpolate ${name}
source = """
module M {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
"""
```

### File Paths

When using `compile_file/1` in tests, remember that tests run from `apps/skein_compiler/`:

```elixir
# Correct: relative from apps/skein_compiler/
{:module, mod} = Compiler.compile_file("../../examples/hello.skein")
```

## Running Tests

```bash
# All tests
mix test

# Specific test file
mix test apps/skein_compiler/test/skein/parser_test.exs

# Specific test by line number
mix test apps/skein_compiler/test/skein/parser_test.exs:42

# With trace output
mix test --trace
```
