---
title: Type System
description: Skein's type system -- built-in types, type checking, schema derivation, and constraint annotations.
---

## Built-in Types

Skein has a set of built-in primitive and parameterized types. Type annotations are required on all function parameters and return types.

### Primitive Types

| Type | Skein | Core Erlang / BEAM Representation |
|------|-------|----------------------------------|
| `Int` | Integer values | Erlang integer |
| `Float` | Floating-point values | Erlang float |
| `String` | UTF-8 text | Erlang binary |
| `Bool` | `true` / `false` | Erlang atoms `true` / `false` |
| `Uuid` | UUID strings | Erlang binary |
| `Instant` | Timestamps | Erlang binary |
| `Duration` | Time durations | Erlang binary |
| `Email` | Email addresses | Erlang binary |
| `Url` | URL strings | Erlang binary |

### Parameterized Types

| Type | Description |
|------|-------------|
| `Option[T]` | A value that may be absent |
| `Result[T, E]` | A value or an error |
| `List[T]` | Ordered collection |
| `Map[K, V]` | Key-value mapping |
| `Set[T]` | Unique collection |

Parameterized types use bracket syntax:

```skein
Option[String]
Result[User, DbError]
List[Int]
Map[String, User]
```

These parse into `%AST.TypeRef{}` nodes with populated `params` lists.

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

## Type Checking

The analyzer's type checking pass (Pass 2) validates types across function boundaries and expressions.

### What Gets Checked

- **Function return types:** The type of the body expression must match the declared return type
- **Operator types:** Arithmetic operators require numeric operands, comparison operators produce Bool
- **Match arm consistency:** All arms of a match expression must produce the same type
- **Function call arity:** The number of arguments must match the function's parameter count
- **Let binding inference:** Types of local bindings are inferred from their initializer expressions

### Type Errors

When a type mismatch is detected, the analyzer produces a structured error:

```json
{
  "code": "E0020",
  "severity": "error",
  "message": "Type mismatch: expected String, got Int",
  "location": {"file": "example.skein", "line": 5, "col": 3},
  "fix_hint": "Check that the expression matches the expected type"
}
```

### Error Codes

| Code | Description |
|------|-------------|
| E0010 | Undefined identifier |
| E0011 | Duplicate definition |
| E0012 | Missing capability declaration |
| E0020 | Type mismatch — including operator type errors and wrong argument counts for fn, stdlib, and effect calls |
| E0021 | Non-exhaustive match (warning) |
| E0024 | Unknown type name (error); non-exhaustive match on an enum (warning) |
| E0025 | Invalid constraint annotation |

### Match Exhaustiveness

The type checker warns when a match on a boolean is not exhaustive:

```skein
fn check(x: Bool) -> String {
  match x {
    true -> "yes"
    -- warning E0021: missing pattern for 'false'
  }
}
```

## Type Declarations

Record types define structured data:

```skein
type User {
  id: Uuid
  email: String
  name: String
}
```

Enum types define variants with optional associated data:

```skein
enum Status {
  Active
  Suspended(reason: String)
  Deleted
}
```

## Constraint Annotations

Type fields support constraint annotations that flow through to generated JSON schemas:

```skein
type Money {
  amount: Int @min(0)
  currency: String @one_of(["USD", "CAD", "EUR"])
}

type Config {
  max_retries: Int @min(1) @max(10) @default(3)
}
```

### Available Annotations

| Annotation | Applies to | JSON Schema |
|------------|-----------|-------------|
| `@min(n)` | Int, Float | `"minimum": n` |
| `@max(n)` | Int, Float | `"maximum": n` |
| `@one_of([...])` | String | `"enum": [...]` |
| `@default(v)` | Any | `"default": v` |

## JSON Schema Derivation

Type declarations automatically generate JSON schemas via `Skein.CodeGen.SchemaGen`:

```elixir
Skein.CodeGen.SchemaGen.generate(%AST.TypeDecl{
  name: "User",
  fields: [
    %AST.Field{name: "id", type: %AST.TypeRef{name: "Uuid"}, annotations: []},
    %AST.Field{name: "email", type: %AST.TypeRef{name: "String"}, annotations: []},
    %AST.Field{name: "name", type: %AST.TypeRef{name: "String"}, annotations: []}
  ]
})
```

Produces:

```json
{
  "type": "object",
  "properties": {
    "id": {"type": "string", "format": "uuid"},
    "email": {"type": "string"},
    "name": {"type": "string"}
  },
  "required": ["id", "email", "name"]
}
```

### Type to JSON Schema Mapping

| Skein Type | JSON Schema |
|------------|-------------|
| `String` | `{"type": "string"}` |
| `Int` | `{"type": "integer"}` |
| `Float` | `{"type": "number"}` |
| `Bool` | `{"type": "boolean"}` |
| `Uuid` | `{"type": "string", "format": "uuid"}` |
| `Email` | `{"type": "string", "format": "email"}` |
| `Url` | `{"type": "string", "format": "uri"}` |
| `Instant` | `{"type": "string", "format": "date-time"}` |
| `Duration` | `{"type": "string"}` |
| `Option[T]` | Schema for T (not required) |
| `List[T]` | `{"type": "array", "items": <T>}` |
| `Map[K, V]` | `{"type": "object", "additionalProperties": <V>}` |

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

## Enum Variant Matching

Enum variants with fields compile to tagged tuples at runtime. You can pattern match on them in `match` expressions:

```skein
enum Shape {
  Circle(radius: Int)
  Rect(width: Int, height: Int)
}

fn area(s: Shape) -> Int {
  match s {
    Shape.Circle(r) -> r * r
    Shape.Rect(w, h) -> w * h
  }
}
```

At runtime, `Shape.Circle(5)` is represented as the tuple `{:circle, 5}` and `Shape.Rect(3, 4)` as `{:rect, 3, 4}`. Simple variants without fields (like `Active`) compile to atoms (`:active`).

The analyzer checks that all enum variants are covered in a match expression (warning E0024). A wildcard `_` arm satisfies this check.

### Exhaustiveness Caveat

Exhaustiveness checking operates at the **variant level**, not at the value level within variant fields. For example:

```skein
enum Action {
  GetUser(id: Int)
  DeleteUser(id: Int)
}

fn handle(a: Action) -> String {
  match a {
    Action.GetUser(5) -> "found user 5"   -- only matches id=5
    Action.DeleteUser(id) -> "deleted"
  }
}
```

The analyzer considers `GetUser` covered because an arm exists for it. However, at runtime, `Action.GetUser(10)` would cause a `case_clause` error because the literal `5` does not match `10`. To avoid this, use a variable pattern or add a wildcard arm:

```skein
fn handle(a: Action) -> String {
  match a {
    Action.GetUser(id) -> "found user"     -- matches all GetUser values
    Action.DeleteUser(id) -> "deleted"
  }
}
```

This is consistent with most typed languages — variant-level coverage is checked, but the full domain of contained values is not.
