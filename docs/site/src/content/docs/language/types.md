---
title: Type System
description: Skein's type system -- what's supported today and what's planned.
---

## Current Type Support (Phase 1)

Phase 1 supports four primitive types. Type annotations are parsed and included in the AST, but **type checking is not yet implemented** -- the analyzer is a pass-through stub.

| Type | Skein | Core Erlang / BEAM Representation |
|------|-------|----------------------------------|
| `Int` | Integer values | Erlang integer |
| `Float` | Floating-point values | Erlang float |
| `String` | UTF-8 text | Erlang binary |
| `Bool` | `true` / `false` | Erlang atoms `true` / `false` |

## Type Annotations

Functions require explicit type annotations on all parameters and the return type:

```skein
fn add(a: Int, b: Int) -> Int {
  a + b
}

fn greet(name: String) -> String {
  "Hello, ${name}!"
}

fn is_positive(n: Int) -> Bool {
  n > 0
}
```

These annotations are stored in the AST as `%AST.TypeRef{}` nodes:

```elixir
%AST.TypeRef{name: "Int", params: [], meta: %{line: 1, col: 15, file: "example.skein"}}
```

## Parameterized Types (Parsed, Not Compiled)

The parser supports parameterized types with bracket syntax:

```skein
Option[String]
Result[User, DbError]
List[Int]
Map[String, User]
```

These parse into `%AST.TypeRef{}` nodes with populated `params` lists. They are not yet compiled or type-checked.

## Type Declarations (Parsed, Not Compiled)

Record types:

```skein
type User {
  id: Uuid
  email: String
  name: String
}
```

Enum types with optional variant data:

```skein
enum Status {
  Active
  Suspended(reason: String)
  Deleted
}
```

## How Types Are Represented in the AST

```elixir
# Simple type
%AST.TypeRef{name: "String", params: []}

# Parameterized type
%AST.TypeRef{
  name: "Result",
  params: [
    %AST.TypeRef{name: "User", params: []},
    %AST.TypeRef{name: "DbError", params: []}
  ]
}

# Type declaration
%AST.TypeDecl{
  name: "User",
  fields: [
    %AST.Field{name: "id", type: %AST.TypeRef{name: "Uuid"}, annotations: []},
    %AST.Field{name: "email", type: %AST.TypeRef{name: "String"}, annotations: []}
  ]
}
```

## What's Coming in Phase 2

Phase 2 will add:

- **Type checking** -- verify function arguments match declared parameter types, return expressions match declared return types
- **Type inference for `let`** -- infer types of local bindings from their initializer expressions
- **`Option[T]` and `Result[T, E]`** as built-in parameterized types with special handling
- **`!` operator** -- unwrap a `Result`, crash on `Err`
- **`?` operator** -- propagate an `Err`, early return from the enclosing function
- **Match exhaustiveness** -- warn when not all enum variants are covered
- **Schema derivation** -- automatically generate JSON Schema from type declarations
- **Constraint annotations** -- `@min(0)`, `@max(100)`, `@one_of(["USD", "EUR"])`, `@default(25)`
