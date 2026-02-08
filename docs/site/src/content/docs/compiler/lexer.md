---
title: Lexer
description: How the Skein lexer tokenizes source code.
---

## Overview

The lexer (`Skein.Lexer`) converts UTF-8 source text into a flat list of tokens. It's implemented as a hand-written recursive descent tokenizer using NimbleParsec for some low-level parsing.

**Location:** `apps/skein_compiler/lib/skein/lexer.ex` (~441 lines)

## Token Format

Tokens are tuples with positional information:

```elixir
# Keywords and punctuation (no value)
{:token_type, {line, col}}

# Tokens with values
{:token_type, {line, col}, value}
```

Line and column numbers are 1-indexed.

### Examples

```elixir
Skein.Lexer.tokenize("let x = 42")
#=> {:ok, [
#     {:let, {1, 1}},
#     {:ident, {1, 5}, "x"},
#     {:eq, {1, 7}},
#     {:int, {1, 9}, 42},
#     {:eof, {1, 11}}
#   ]}
```

## Token Categories

### Keywords

Reserved words that cannot be used as identifiers:

```skein
module  fn       let      match    type     enum
handler agent    tool     capability supervisor test
scenario golden  on       emit     transition stop
suspend resume   true     false    implement  input
output  errors   policy   description state  strategy
child   replay   given    expect   assert
```

Each keyword tokenizes to its corresponding atom: `"module"` becomes `{:module, {line, col}}`.

### Identifiers

```elixir
# Lowercase identifiers (variables, function names)
{:ident, {1, 1}, "hello"}
{:ident, {1, 1}, "my_variable"}

# Uppercase identifiers (types, module names)
{:upper_ident, {1, 1}, "String"}
{:upper_ident, {1, 1}, "UserService"}
```

Lowercase identifiers start with `[a-z]` and may contain `[a-z0-9_]`.
Uppercase identifiers start with `[A-Z]` and may contain `[a-zA-Z0-9]`.

### Literals

```elixir
# Integers
{:int, {1, 1}, 42}

# Floats
{:float, {1, 1}, 3.14}

# Strings (with interpolation segments)
{:string, {1, 1}, [{:literal, "Hello, "}, {:interpolation, {:ident, {1, 10}, "name"}}, {:literal, "!"}]}
```

### Operators and Punctuation

```elixir
# Arithmetic
:plus       # +
:minus      # -
:star       # *
:slash      # /

# Comparison
:eq_eq      # ==
:neq        # !=
:lt         # <
:gt         # >
:lte        # <=
:gte        # >=

# Logical
:and_and    # &&
:or_or      # ||

# Assignment and arrows
:eq         # =
:arrow      # ->

# Punctuation
:lbrace     # {
:rbrace     # }
:lparen     # (
:rparen     # )
:lbracket   # [
:rbracket   # ]
:comma      # ,
:dot        # .
:colon      # :
:pipe       # |>
:bang       # !
:question   # ?
:at         # @
:ampersand  # &

# Special
:eof        # End of input
```

## String Tokenization

Strings are tokenized with interpolation support. The lexer produces a list of segments:

```elixir
# Plain string: "hello"
{:string, {1, 1}, [{:literal, "hello"}]}

# Interpolated: "Hello, ${name}!"
{:string, {1, 1}, [
  {:literal, "Hello, "},
  {:interpolation, {:ident, {1, 10}, "name"}},
  {:literal, "!"}
]}

# Empty string: ""
{:string, {1, 1}, []}
```

Interpolation uses `${}` syntax. Inside the braces, the lexer produces a nested token for the expression (currently only identifiers are supported in interpolation).

## Comments

Single-line comments start with `--` and run to end of line:

```skein
-- this is a comment
let x = 42  -- inline comment
```

Comments are consumed by the lexer and not included in the token stream.

## Whitespace Handling

Whitespace (spaces, tabs, newlines) is consumed between tokens and used only for position tracking. Newlines increment the line counter and reset the column counter.

## Error Handling

The lexer returns `{:error, [%Skein.Error{}]}` for unrecognized characters:

```elixir
Skein.Lexer.tokenize("let x = @#$")
#=> {:error, [%Skein.Error{code: "E001", message: "Unexpected character: #", ...}]}
```

## Property-Tested Invariants

The lexer has 11 property-based tests verifying:

- Any valid lowercase identifier tokenizes to `:ident`
- Any valid uppercase identifier tokenizes to `:upper_ident`
- Any positive integer tokenizes to `:int` with the correct value
- Quoted strings produce `:string` tokens with preserved content
- Token lists always end with `:eof`
- Token positions are always positive (line >= 1, col >= 1)
- All keywords tokenize to their corresponding atoms
- Whitespace-separated identifiers produce the correct token count
- Newlines correctly increment line numbers
- String interpolation preserves identifier names
