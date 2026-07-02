---
title: Storage
description: How Skein's store.table operations execute against the ETS-backed runtime store, and the status of the unwired Ecto/SQLite typed-table path.
---

## Overview

Skein provides storage through the `store.table` capability. Store tables are typed: every declaration names both the table and the record type it stores — `capability store.table("users", User)` — where the record type is a declared `type` in the same module with exactly one `@primary` field (the get/delete key). The analyzer type-checks every `store.<table>` operation against that record type, and writes are schema-checked at runtime. At runtime, every compiled `store.*` call executes against `Skein.Runtime.Store` — an ETS-backed key-value store (a single `:skein_store` table keyed by string table names) with capability enforcement and tracing. That is the only storage path compiled programs hit today.

An Ecto/SQLite persistent-table layer also exists in the codebase (`StoreEcto`, `EctoSchema`, `MigrationGen`, `Repo`), but it is **not wired into compilation or boot** — nothing registers schemas or runs migrations for compiled programs, and there is no backend-selection mechanism. It is library code exercised only by its own tests. The compiler half of typed store tables is roadmap item C5 ([#255](https://github.com/kormie/Skein/issues/255)); wiring the persistence path remains future work.

## Architecture

The live store module:

| Module | Purpose |
|--------|---------|
| `Skein.Runtime.Store` | ETS-backed CRUD operations (get, put, delete, query) with capability enforcement and tracing — the target of every compiled `store.*` call |

The unwired Ecto layer (dead library code today, the intended basis for C5 typed tables):

| Module | Purpose |
|--------|---------|
| `Skein.Runtime.StoreEcto` | CRUD operations (get, put, delete, query) with capability enforcement and tracing |
| `Skein.Runtime.EctoSchema` | Dynamically generates Ecto schema modules from Skein type declarations |
| `Skein.Runtime.MigrationGen` | Generates and executes Ecto migrations to create/modify tables |
| `Skein.Runtime.Repo` | Ecto Repo configured for SQLite3 via `ecto_sqlite3` |

## The Unwired Ecto Path

The sections below describe what the Ecto modules do when called directly (as their tests do). Compiled Skein programs do **not** invoke any of this today.

### 1. Schema Generation

Given a table name and field descriptions (the shape the compiler could extract from a `type` declaration), `EctoSchema.build_schema/2` creates a dynamic Ecto schema module.

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

`StoreEcto` mirrors the `store.*` API, but requires manual schema registration — nothing does this automatically for compiled programs:

```elixir
# Register the schema (manual — only the StoreEcto tests do this today)
StoreEcto.register_schema("users", schema_mod)

# Insert or upsert a record
StoreEcto.put("users", %{id: "u1", email: "alice@test.com", name: "Alice"}, caps)
#=> {:ok, %{id: "u1", email: "alice@test.com", name: "Alice"}}

# Get by primary key
StoreEcto.get("users", "u1", caps)
#=> {:ok, %{id: "u1", email: "alice@test.com", name: "Alice"}}

# Query with filters
# Filters are an equality map; matching records come back wrapped in :ok
StoreEcto.query("users", %{email: "alice@test.com"}, caps)
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
  capability store.table("users", User)
  capability http.in

  type User {
    id: Uuid @primary
    email: String @unique
    name: String
    created_at: Instant
  }

  handler http GET "/users/:id" (req) -> {
    match store.users.get(req.params.id) {
      Ok(u)         -> respond.json(200, u)
      Err(NotFound) -> respond.json(404, { error: "not found" })
    }
  }

  handler http POST "/users" (req) -> {
    let data = req.json[User]()?
    let user = store.users.put(data)!
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

## The ETS Store

`Skein.Runtime.Store` is the store: an in-memory, ETS-backed key-value implementation that every compiled `store.*` call targets. It requires no database setup. There is no backend-selection or dispatch mechanism — compiled code calls `Skein.Runtime.Store` directly, so data does not survive a restart. Persistent, typed tables are the C5 roadmap work ([#255](https://github.com/kormie/Skein/issues/255), v0.5.0).

## Configuration

The (unwired) Ecto layer uses SQLite3 -- the `ecto_sqlite3` adapter is hardcoded in `Skein.Runtime.Repo` at compile time, and `postgrex` is not a dependency. If you start the Repo yourself, connection options (database path, pool size) come from standard Ecto config:

```elixir
# Skein.Runtime.Repo configuration
config :skein_runtime, Skein.Runtime.Repo,
  database: "skein_dev.db",
  pool_size: 5
```

Other database adapters (e.g. Postgres) are a possible future direction; SQLite3 is the adapter the C5 typed-table work would build on.
