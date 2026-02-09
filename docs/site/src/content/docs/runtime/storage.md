---
title: Storage
description: How Skein's store.table operations map to Ecto and SQLite at runtime, including schema generation, migrations, and queries.
---

## Overview

Skein provides typed database storage through the `store.table` capability. At compile time, type declarations generate database schemas. At runtime, `store.*` operations execute real database queries via Ecto against SQLite (local dev) or Postgres (production).

## Architecture

The storage system has four runtime modules:

| Module | Purpose |
|--------|---------|
| `Skein.Runtime.StoreEcto` | CRUD operations (get, put, delete, query) with capability enforcement and tracing |
| `Skein.Runtime.EctoSchema` | Dynamically generates Ecto schema modules from Skein type declarations |
| `Skein.Runtime.MigrationGen` | Generates and executes Ecto migrations to create/modify tables |
| `Skein.Runtime.Repo` | Ecto Repo configured for SQLite3 via `ecto_sqlite3` |

## How It Works

### 1. Schema Generation

When a Skein module declares `capability store.table("users")` with a `type User { ... }`, the compiler extracts the type's fields and annotations. At runtime, `EctoSchema.build_schema/2` creates a dynamic Ecto schema module.

```elixir
fields = [
  %{name: "id", type: "Uuid", annotations: [%{name: "primary"}]},
  %{name: "email", type: "String", annotations: [%{name: "unique"}]},
  %{name: "name", type: "String", annotations: []}
]

{:ok, schema_mod} = Skein.Runtime.EctoSchema.build_schema("users", fields)
```

**Type mapping:**

| Skein Type | Ecto Type |
|-----------|-----------|
| `String` | `:string` |
| `Int` | `:integer` |
| `Float` | `:float` |
| `Bool` | `:boolean` |
| `Uuid` | `:binary_id` |
| `Instant` | `:utc_datetime` |
| `Option[T]` | Inner type (nullable) |

### 2. Migration Generation

`MigrationGen.build_migration/2` creates an Ecto migration module that:
- Creates the table with the correct column types
- Sets the primary key based on `@primary` annotations
- Adds unique indexes for `@unique` annotations

```elixir
{:ok, migration_mod} = Skein.Runtime.MigrationGen.build_migration("users", fields)
:ok = Skein.Runtime.MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)
```

### 3. CRUD Operations

`StoreEcto` provides the standard `store.*` API:

```elixir
# Register the schema (done automatically during compilation)
StoreEcto.register_schema("users", schema_mod)

# Insert or upsert a record
StoreEcto.put("users", %{id: "u1", email: "alice@test.com", name: "Alice"}, caps)
#=> {:ok, %{id: "u1", email: "alice@test.com", name: "Alice"}}

# Get by primary key
StoreEcto.get("users", "u1", caps)
#=> {:ok, %{id: "u1", email: "alice@test.com", name: "Alice"}}

# Query with filters
StoreEcto.query("users", [email: "alice@test.com"], caps)
#=> {:ok, [%{id: "u1", email: "alice@test.com", name: "Alice"}]}

# Delete by primary key
StoreEcto.delete("users", "u1", caps)
#=> {:ok, "u1"}
```

Every operation:
1. Validates `store.table` capability for the target table
2. Performs the Ecto query (using upsert semantics with `ON CONFLICT DO UPDATE` for `put`)
3. Records a trace span with timing and outcome
4. Returns `{:ok, result}` or `{:error, reason}`

## Skein Source Example

```skein
module UserService {
  capability store.table("users")
  capability http.in

  type User {
    id: Uuid @primary
    email: String @unique
    name: String
    created_at: Instant
  }

  handler http GET "/users/:id" (req) -> {
    let user = store.users.get(req.params.id)
    respond.json(200, user)
  }

  handler http POST "/users" (req) -> {
    let data = req.json[User]
    let user = store.users.put(data)
    respond.json(201, user)
  }
}
```

## Compiled Code

The code generator transforms `store.*` calls into runtime calls:

```skein
-- Skein source:
store.users.get(id)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Store':'get'("users", Id, Capabilities)
```

Where `Capabilities` is a literal list built from the module's `capability` declarations at compile time.

## ETS Backend

For testing and simple use cases, `Skein.Runtime.Store` provides an ETS-backed in-memory store with the same API. This is the default backend and requires no database setup.

## Configuration

The Ecto backend uses SQLite3 for local development:

```elixir
# Skein.Runtime.Repo configuration
config :skein_runtime, Skein.Runtime.Repo,
  database: "skein_dev.db",
  pool_size: 5
```

For production deployments, configure Postgres via `postgrex`.
