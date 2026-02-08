---
title: Compilation Pipeline
description: How Skein source code becomes running BEAM bytecode.
---

## Pipeline Overview

```
Source (.skein)
    |
    v
+---------+
|  Lexer  |  Source text -> Token stream
+----+----+
     |
     v
+---------+
| Parser  |  Token stream -> AST
+----+----+
     |
     v
+----------+
| Analyzer |  AST -> Annotated AST (stub in Phase 1)
+----+-----+
     |
     v
+----------+
| CodeGen  |  AST -> Core Erlang AST (via :cerl module)
+----+-----+
     |
     v
+---------------+
| :compile.forms|  Core Erlang -> BEAM bytecode
+----+----------+
     |
     v
+------------------+
| :code.load_binary|  BEAM bytecode -> Loaded module
+------------------+
```

## Entry Points

The compiler has two entry points in `Skein.Compiler`:

### `compile_string/1`

Compiles a Skein source string to a loaded BEAM module:

```elixir
{:module, mod} = Skein.Compiler.compile_string(~S"""
module Math {
  fn add(a: Int, b: Int) -> Int {
    a + b
  }
}
""")
mod.add(3, 4) #=> 7
```

### `compile_file/1`

Reads a `.skein` file and compiles it:

```elixir
{:module, mod} = Skein.Compiler.compile_file("examples/hello.skein")
```

Both return `{:module, module()}` on success or `{:error, [Skein.Error.t()]}` on failure.

## Pipeline Stages

### Stage 1: Lexer

**Input:** UTF-8 source string
**Output:** `{:ok, [token()]}` or `{:error, [Error.t()]}`

Converts source text to a flat list of tokens. Each token is a tuple:

```elixir
{:keyword, {line, col}}           # e.g. {:module, {1, 1}}
{:token_type, {line, col}, value} # e.g. {:ident, {1, 8}, "hello"}
```

See [Lexer](/Skein/compiler/lexer/) for details.

### Stage 2: Parser

**Input:** Token list
**Output:** `{:ok, %AST.Module{}}` or `{:error, [Error.t()]}`

Builds a structured AST from the token stream using recursive descent with Pratt-style operator precedence.

See [Parser](/Skein/compiler/parser/) for details.

### Stage 3: Analyzer

**Input:** AST
**Output:** `{:ok, annotated_ast}` (currently pass-through)

In Phase 1, the analyzer simply returns the AST unchanged. Future phases will add:
- Name resolution
- Type checking
- Capability checking
- Transition validation (for agents)

### Stage 4: Code Generator

**Input:** AST
**Output:** `{:ok, beam_binary}` or `{:error, [Error.t()]}`

Translates the AST to Core Erlang using the `:cerl` module, then compiles to BEAM bytecode via `:compile.forms/2`.

See [Code Generator](/Skein/compiler/codegen/) for details.

### Stage 5: Module Loading

The final step uses `:code.load_binary/3` to load the BEAM bytecode into the running VM:

```elixir
:code.load_binary(module_name, ~c"nofile", beam_binary)
# Returns {:module, module_atom}
```

The module is immediately available for function calls.

## Error Handling

Each stage returns `{:ok, result}` or `{:error, errors}`. The `with` construct chains them:

```elixir
def compile_string(source) do
  with {:ok, tokens} <- Lexer.tokenize(source),
       {:ok, ast} <- Parser.parse(tokens),
       {:ok, annotated_ast} <- Analyzer.analyze(ast),
       {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
    module_name = module_name_from_ast(annotated_ast)
    :code.load_binary(module_name, ~c"nofile", beam_binary)
  end
end
```

If any stage fails, the error propagates immediately. Errors are `%Skein.Error{}` structs with structured fields for both human and machine consumption.
