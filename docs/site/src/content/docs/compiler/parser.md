---
title: Parser
description: How the Skein parser builds ASTs from token streams.
---

## Overview

The parser (`Skein.Parser`) is a hand-written recursive descent parser that converts a token stream into an Abstract Syntax Tree (AST). It uses Pratt-style precedence climbing for expression parsing.

**Location:** `apps/skein_compiler/lib/skein/parser.ex` — the largest compiler stage alongside the code generator

## Entry Point

```elixir
{:ok, tokens} = Skein.Lexer.tokenize(source)
{:ok, %Skein.AST.Module{}} = Skein.Parser.parse(tokens)

# With file name for error reporting
{:ok, ast} = Skein.Parser.parse(tokens, "hello.skein")
```

## Parsing Strategy

### Recursive Descent

Each grammar production has a corresponding `parse_*` function:

```
parse_module       -> module Name { declarations... }
parse_declaration  -> fn | type | enum | capability | handler | ...
parse_fn           -> fn name(params) -> Type { body }
parse_block        -> { expressions... }
parse_expression   -> parse_pipe_expr (top of precedence chain)
```

### Precedence Climbing

Expressions are parsed using a chain of functions, each handling one precedence level. Lower-precedence functions call higher-precedence ones:

```
parse_pipe_expr          level 1 (lowest): |>
  -> parse_or_expr       level 2: ||
    -> parse_and_expr    level 3: &&
      -> parse_equality  level 4: ==, !=
        -> parse_compare level 5: <, >, <=, >=
          -> parse_add   level 6: +, -
            -> parse_mul level 7: *, /
              -> parse_unary    level 8: !, - (prefix)
                -> parse_postfix level 9: !, ? (postfix)
                  -> parse_primary  level 10: literals, identifiers, calls
```

Each level parses its operator, delegates to the next level for operands, and builds `%AST.BinaryOp{}` or `%AST.UnaryOp{}` nodes.

### Left-Associative Parsing

Binary operators at the same precedence level are left-associative. The parser handles this with a continuation loop:

```
a + b + c  ->  (a + b) + c

BinaryOp(+,
  BinaryOp(+, a, b),
  c
)
```

## What Gets Parsed

### Module Declarations

```skein
module Hello { ... }
```

Produces `%AST.Module{name: "Hello", declarations: [...], meta: %{...}}`.

### Function Declarations

```skein
fn add(a: Int, b: Int) -> Int {
  a + b
}
```

Produces `%AST.Fn{name: "add", params: [...], return_type: %AST.TypeRef{}, body: %AST.Block{}, meta: %{...}}`.

Parameters are `%AST.Field{name: "a", type: %AST.TypeRef{name: "Int"}}`.

### Let Bindings

```skein
let x = 42
let result = compute(y)
```

Produces `%AST.Let{name: "x", value: %AST.IntLit{value: 42}}`.

### Match Expressions

```skein
match expr {
  true  -> "yes"
  false -> "no"
}
```

Produces `%AST.Match{subject: expr, arms: [%AST.MatchArm{pattern: ..., body: ...}, ...]}`.

### Binary Operations

```skein
a + b * c
```

Respects precedence:

```elixir
%AST.BinaryOp{
  op: :+,
  left: %AST.Identifier{name: "a"},
  right: %AST.BinaryOp{
    op: :*,
    left: %AST.Identifier{name: "b"},
    right: %AST.Identifier{name: "c"}
  }
}
```

### Pipe Expressions

```skein
data |> transform() |> validate()
```

Produces a chain of `%AST.Pipe{}` nodes (left-associative).

### Function Calls

```skein
add(3, 4)
```

Produces `%AST.Call{target: %AST.Identifier{name: "add"}, args: [...]}`.

### Field Access

```skein
user.name
user.address.city
```

Produces nested `%AST.FieldAccess{}` nodes.

### String Literals

```skein
"Hello, ${name}!"
```

Produces `%AST.StringLit{segments: [{:literal, "Hello, "}, {:interpolation, {:ident, _, "name"}}, {:literal, "!"}]}`.

### Type and Enum Declarations

```skein
type User {
  name: String
  age: Int
}

enum Status {
  Active
  Suspended(reason: String)
}
```

These parse to `%AST.TypeDecl{}` and `%AST.EnumDecl{}` nodes.

### Capability Declarations

```skein
capability http.out("api.example.com")
```

Parses to `%AST.Capability{}`.

## Pattern Matching

Match arm patterns support:

| Pattern | Example | AST Node |
|---------|---------|----------|
| Boolean literal | `true`, `false` | `%AST.BoolLit{}` |
| Integer literal | `0`, `42` | `%AST.IntLit{}` |
| String literal | `"active"` | `%AST.StringLit{}` |
| Variable binding | `x`, `name` | `%AST.Identifier{}` |
| Wildcard | `_` | `%AST.Identifier{name: "_"}` |
| Enum variant (bare) | `Active`, `Status.Active` | `%AST.Identifier{}` |
| Enum variant (with fields) | `Banned(reason)`, `Status.Banned(reason)` | `%AST.Call{target: %AST.Identifier{}, args: [...]}` |

Variant field arguments are themselves patterns, so they nest (bindings, literals, wildcards).

### Match Guards

A match arm pattern may carry a guard: `pattern if expr ->`. The contextual keyword `if` between the pattern and the arrow introduces a guard expression, stored on the arm's `guard` field (`nil` when absent):

```skein
match amount {
  n if n > 100 -> "large"
  n -> "small"
}
```

## Source Location Tracking

Every AST node carries a `meta` field with source location:

```elixir
%{line: 5, col: 3, file: "hello.skein"}
```

This is used for error reporting and debugging. The parser extracts position from each token's `{line, col}` tuple.

## Error Handling

Parse errors produce structured `%Skein.Error{}` values:

```elixir
Skein.Parser.parse([{:ident, {1, 1}, "x"}, {:eof, {1, 2}}])
#=> {:error, [%Skein.Error{message: "Expected 'module' keyword", ...}]}
```

## Property-Tested Invariants

The parser has 8 property-based tests verifying:

- Any generated module source lexes and parses successfully
- Parsed module name matches the generated name
- Number of parsed fn declarations matches the number generated
- Every parsed function has a return type
- Every parsed function has a block body
- Every AST node carries source location metadata
- Match expressions on booleans produce exactly 2 arms
- Empty modules parse with zero declarations
