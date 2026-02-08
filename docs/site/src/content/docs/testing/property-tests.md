---
title: Property-Based Tests
description: How Skein uses StreamData generators for property-based testing.
---

## Why Property Tests?

Unit tests verify specific examples. Property tests verify **invariants across large input spaces** using randomly generated data. For a compiler, this means:

- Testing the lexer against thousands of random valid identifiers
- Testing the parser against randomly generated Skein programs
- Testing the code generator by compiling random programs and verifying runtime behavior matches expectations

## Libraries

| Library | Purpose | Status |
|---------|---------|--------|
| `StreamData` / `ExUnitProperties` | Generator-based property testing | Active, 49 properties |
| `PropCheck` (PropEr) | Stateful/state-machine testing | Installed, not yet used |

`StreamData` is used for all current property tests. `PropCheck` is available for future stateful testing of the runtime (agent lifecycle, store operations).

## Test Files

```
apps/skein_compiler/test/skein/
  lexer_property_test.exs          # 11 properties
  parser_property_test.exs         # 20 properties (incl. scenario/golden)
  codegen/
    core_erlang_property_test.exs  # 9 properties
  analyzer_property_test.exs       # 9 properties
apps/skein_runtime/test/skein/runtime/
  capability_property_test.exs     # 5 properties
  request_property_test.exs        # 6 properties
  store_property_test.exs          # 5 properties
  tool_property_test.exs           # 5 properties
```

## Lexer Properties (11 tests)

The lexer property tests use generators for valid identifiers, integers, and strings, then verify tokenization invariants.

### Generators

```elixir
# Lowercase identifiers: starts with a-z, followed by a-z, 0-9, _
defp lower_ident_gen do
  gen all first <- StreamData.member_of(Enum.to_list(?a..?z)),
          rest <- StreamData.list_of(
            StreamData.member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_]),
            min_length: 0, max_length: 20
          ) do
    name = List.to_string([first | rest])
    if name in @keywords, do: "z" <> name, else: name
  end
end
```

Note the keyword avoidance -- if a random identifier happens to match a keyword, it's prefixed with `"z"`.

### Properties Verified

- Any valid lowercase identifier tokenizes to `:ident`
- Any valid uppercase identifier tokenizes to `:upper_ident`
- Any positive integer tokenizes to `:int` with that value
- Quoted strings produce `:string` tokens
- Simple string content round-trips (literal is preserved)
- Token lists always end with `:eof`
- Token positions are always positive (line >= 1, col >= 1)
- All keywords tokenize to their corresponding atoms
- Whitespace-separated identifiers produce correct token count
- Newlines increment line numbers correctly
- String interpolation preserves the identifier name

## Parser Properties (20 tests)

The parser properties generate **valid Skein source programs** and verify structural invariants. This includes functions, tool declarations, scenario tests, and golden tests.

### Source Generators

The generators build valid Skein source strings compositionally:

```elixir
# Generate a valid function
defp fn_gen do
  gen all name <- lower_ident_gen(),
          params <- StreamData.list_of(param_gen(), min_length: 0, max_length: 3),
          ret_type <- type_name_gen(),
          body <- body_expr_gen() do
    params_str = Enum.join(params, ", ")
    "fn #{name}(#{params_str}) -> #{ret_type} {\n    #{body}\n  }"
  end
end

# Generate a valid module
defp module_gen do
  gen all mod_name <- upper_ident_gen(),
          fns <- StreamData.list_of(fn_gen(), min_length: 1, max_length: 4) do
    body = Enum.map_join(fns, "\n  ", & &1)
    "module #{mod_name} {\n  #{body}\n}"
  end
end
```

### Properties Verified

- Any generated module source lexes and parses successfully
- Parsed module name matches the generated name
- Number of parsed fn declarations matches number generated
- Every parsed function has a return type (`%AST.TypeRef{}`)
- Every parsed function has a block body (`%AST.Block{}`)
- Every AST node carries source location metadata (line >= 1, col >= 1)
- Match on booleans always produces exactly 2 arms
- Empty modules parse with zero declarations
- Any generated scenario lexes and parses successfully
- Scenario description matches generated description
- Scenario given var count matches generated bindings
- Scenario preserves source location metadata
- Any generated golden declaration lexes and parses successfully
- Golden trace file matches generated path
- Golden preserves source location metadata

## CodeGen Properties (9 tests)

The codegen properties test the **full pipeline** -- generate random inputs, compile Skein source to BEAM, call the compiled functions, and verify results match Elixir semantics.

### Unique Module Names

Each property test iteration creates a unique module to avoid BEAM module name collisions:

```elixir
defp unique_module_name do
  counter = System.unique_integer([:positive, :monotonic])
  "PropMod#{counter}"
end
```

### Example Property

```elixir
property "integer addition compiles and computes correctly" do
  check all a <- StreamData.integer(-1000..1000),
            b <- StreamData.integer(-1000..1000) do
    mod_name = unique_module_name()

    source = """
    module #{mod_name} {
      fn add(a: Int, b: Int) -> Int {
        a + b
      }
    }
    """

    {:module, mod} = Compiler.compile_string(source)
    assert mod.add(a, b) == a + b
  end
end
```

This generates random integer pairs, compiles a Skein `add` function for each, and verifies the result matches Elixir's `+` operator.

### Properties Verified

- Integer addition computes correctly
- Integer subtraction computes correctly
- Integer multiplication computes correctly
- Comparison `>` produces correct booleans
- Equality `==` produces correct booleans
- String interpolation round-trips alphanumeric input
- Let bindings preserve computed values
- Match on `> 0` correctly classifies positive vs non-positive
- Plain string literals return exact strings

## Writing New Properties

### Pattern

```elixir
property "description of the invariant" do
  check all input <- generator() do
    # Exercise the code under test
    result = function_under_test(input)

    # Assert the invariant holds
    assert invariant(result, input)
  end
end
```

### Generator Tips

- Use `StreamData.member_of/1` for selecting from a known set
- Use `StreamData.one_of/1` for choosing between generator types
- Use `gen all` for composing multiple generators
- Guard against accidentally generating keywords when making identifiers
- Use `System.unique_integer([:positive, :monotonic])` for unique names in codegen tests

### Running Property Tests

```bash
# All tests including properties
mix test

# Just property tests
mix test --only property

# With more iterations (default is 100)
# Configure in the check call: check all ..., max_runs: 1000 do
```
