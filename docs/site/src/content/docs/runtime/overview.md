---
title: Runtime
description: The Skein runtime library -- agents, HTTP client, handler dispatch, store, memory, LLM client, queue/schedule dispatch, capability enforcement, trace recording, and HTTP server.
---

## Overview

The Skein runtime (`skein_runtime`) provides the libraries that compiled Skein code calls at execution time. It handles:

- **Agent runtime** -- GenStateMachine-based state machines for Skein agents via `Skein.Runtime.Agent`
- **HTTP client** -- making outbound HTTP requests via `Skein.Runtime.Http`
- **Capability enforcement** -- validating effect calls against declared capabilities
- **Handler dispatch** -- routing HTTP requests to compiled handler functions
- **Queue dispatch** -- subscribing to named queues and dispatching messages via `Skein.Runtime.Queue`
- **Schedule dispatch** -- cron-based scheduling and handler triggering via `Skein.Runtime.Schedule`
- **Store** -- pluggable storage with ETS (default) and Ecto/SQLite backends, capability enforcement
- **Memory** -- scoped KV storage with namespace isolation via `Skein.Runtime.Memory`
- **LLM client** -- provider-agnostic LLM calls with schema-constrained JSON via `Skein.Runtime.Llm`
- **HTTP server** -- Bandit + Plug HTTP server for serving Skein handlers
- **Unified event store** -- a single append-only event log for all trace spans, user events, memory state changes, and annotations via `Skein.Runtime.EventStore`

The runtime is an OTP application that starts automatically when Skein code is loaded.

## Runtime Modules

### `Skein.Runtime.Agent`

Runtime support for Skein agent state machines. Wraps `:gen_statem` to manage the agent lifecycle -- starting agents, executing phase handlers, processing transitions, and recording events.

**API:**

```elixir
Skein.Runtime.Agent.start_link(module, args)
#=> {:ok, pid}

Skein.Runtime.Agent.get_phase(pid)
#=> :review

# State always starts empty — start params are passed to the on start
# handler but never copied into state; handlers populate memory instead.
Skein.Runtime.Agent.get_state(pid)
#=> %{}

# Events are keyed :event with the PascalCase event name from `emit`.
Skein.Runtime.Agent.get_events(pid)
#=> [%{event: "RefundApproved", amount: 100}]
```

**How it works:**

1. `start_link/2` starts a `:gen_statem` process with the agent module and initial args
2. The `init` callback calls the module's `__start_handler__/2` to run the `on start` handler
3. `transition(Phase)` in a handler returns `{:transition, phase, state, events}`, which moves the gen_statem to the new state and queues an `:execute_phase` internal event
4. The internal event triggers the module's `__phase_handler__/3` for the target phase
5. Phase handlers can transition again, emit events, update state, or stop the agent
6. `stop()` terminates the agent process normally
7. `emit(event)` appends to the event log, queryable via `get_events/1`

Each compiled Skein agent generates:
- `start_link/1` -- start the agent with initial params
- `__phases__/0` -- return phase metadata (variants and transitions)
- `__start_handler__/2` -- the `on start(...)` handler
- `__phase_handler__/3` -- phase-specific handlers dispatched by phase name

See the [Agents page](/Skein/runtime/agents/) for detailed documentation.

### `Skein.Runtime.Http`

The HTTP client wraps Erlang's built-in `:httpc` module. It is the target of compiled `http.get`, `http.post`, etc. calls.

**API:**

```elixir
Skein.Runtime.Http.get(url, capabilities)
#=> {:ok, body} | {:error, reason}

Skein.Runtime.Http.post(url, body, capabilities)
#=> {:ok, body} | {:error, reason}

Skein.Runtime.Http.put(url, body, capabilities)
Skein.Runtime.Http.patch(url, body, capabilities)
Skein.Runtime.Http.delete(url, capabilities)
```

Every call:
1. Checks the URL against `capabilities` via `Skein.Runtime.Capability`
2. If allowed, makes the HTTP request
3. Records a trace span with timing and outcome
4. Returns `{:ok, body}` for 2xx responses, `{:error, reason}` otherwise

The runtime uses `:httpc` rather than a third-party HTTP library to minimize dependencies. The `:inets` and `:ssl` OTP applications are started automatically.

### `Skein.Runtime.Capability`

Provides runtime capability enforcement -- the second layer of defense beyond compile-time checking.

**API:**

```elixir
Skein.Runtime.Capability.check_http(url, capabilities)
#=> :ok | {:error, reason}

Skein.Runtime.Capability.extract_host(url)
#=> {:ok, host} | {:error, reason}
```

**How checking works:**

1. Extract the host from the URL
2. Filter capabilities to find `http.out` entries
3. If any capability has empty params (wildcard), allow
4. Otherwise, check if the URL host appears in any capability's params
5. Return `:ok` or `{:error, "Host 'x' not declared in http.out capabilities"}`

### `Skein.Runtime.Handler`

Dispatches incoming HTTP requests to compiled Skein handler functions. Handles route matching with path parameters, request construction, and response encoding.

**API:**

```elixir
Skein.Runtime.Handler.dispatch(module, method, path, headers, body)
#=> {:ok, status, body, content_type} | {:error, reason}
# content_type is :json, :text, or :html
```

**Features:**
- Route matching with path parameters (`:id` syntax)
- HTTP method dispatching (GET, POST, PUT, PATCH, DELETE)
- Request map construction with `params`, `headers`, `body`, `method`, `path`
- JSON response encoding via Jason
- Trace span recording for each dispatched request

### `Skein.Runtime.Queue`

In-memory message queue dispatch for compiled Skein queue handlers. Manages subscriptions between queue names and handler functions, dispatching published messages asynchronously.

**API:**

```elixir
Skein.Runtime.Queue.subscribe("order-events", MyModule, :__handler_0__)
#=> :ok

Skein.Runtime.Queue.publish("order-events", %{body: "payload"})
#=> :ok (dispatches asynchronously)

Skein.Runtime.Queue.list_queues()
#=> ["order-events", "priority-events"]
```

Features:
- In-order message delivery within a single queue
- Multiple subscribers per queue
- Trace span recording for each dispatched message
- For testing, `subscribe_fn/2` accepts a plain function

### `Skein.Runtime.Schedule`

Cron-based schedule dispatch for compiled Skein schedule handlers. Registered handlers **fire automatically**: a periodic tick (1s by default) evaluates each cron expression against the wall clock and fires matching handlers at most once per cron minute. `Skein.Runtime.Server` registers every `:schedule` entry from a module's `__handlers__/0` at startup, so `skein run` services fire on schedule with no manual intervention.

**API:**

```elixir
Skein.Runtime.Schedule.register("*/5 * * * *", MyModule, :__handler_0__)
#=> :ok

Skein.Runtime.Schedule.trigger("*/5 * * * *")
#=> :ok (triggers all handlers for this expression)

Skein.Runtime.Schedule.parse_cron("0 * * * *")
#=> {:ok, %{minute: "0", hour: "*", day: "*", month: "*", weekday: "*"}}

Skein.Runtime.Schedule.list_schedules()
#=> ["*/5 * * * *", "0 0 * * *"]
```

Features:
- Automatic firing on a configurable tick (`schedule_tick_ms`, default 1s; `schedule_auto_tick: false` disables — the test env does)
- Full 5-field cron matching: `*`, `n`, `a-b`, `*/n`, `a-b/n`, comma lists; weekday 0/7 = Sunday; restricted day-of-month and weekday combine with OR (standard cron rule)
- Per-minute dedup — no duplicate firings within the same cron minute
- Invalid cron expressions are rejected at registration (`{:error, reason}`)
- Manual triggering (`trigger/1`) and deterministic clock injection (`tick_at/1`) for testing
- Trace span recording for each fired handler

### `Skein.Runtime.Store`

ETS-backed key-value storage that compiled `store.table` effect calls target — the only storage path compiled programs hit today (there is no backend-selection mechanism). Store tables are typed (C5, #255): the capability names the table's record type, the compiler type-checks every operation against it, and writes are schema-checked at runtime.

**API:**

```elixir
Skein.Runtime.Store.get(table, id, capabilities)
#=> {:ok, record} | {:error, :not_found}

Skein.Runtime.Store.put(table, record, capabilities)
#=> {:ok, record}

Skein.Runtime.Store.delete(table, id, capabilities)
#=> {:ok, id}

# Filters are an equality map; the matching records come back wrapped in :ok
Skein.Runtime.Store.query(table, %{status: "active"}, capabilities)
#=> {:ok, [record, ...]}
```

Every operation:
1. Validates `store.table` capability for the target table
2. Performs the ETS operation
3. Records a trace span with timing and outcome
4. Returns `{:ok, _}` / `{:error, _}` — including `query`, whose `:ok` payload is the matching-record list

### `Skein.Runtime.StoreEcto`

Ecto-backed storage backend that performs real database operations against SQLite3 (the `ecto_sqlite3` adapter is hardcoded in `Skein.Runtime.Repo`). Uses dynamically-generated Ecto schema modules mapped to Skein type declarations.

**API:** Same as `Skein.Runtime.Store` (get, put, delete, query) with identical capability enforcement and tracing.

**Supporting modules:**
- `Skein.Runtime.EctoSchema` -- generates Ecto schema modules from Skein type fields and annotations (`@primary`, `@unique`)
- `Skein.Runtime.MigrationGen` -- generates and executes Ecto migrations to create/modify database tables
- `Skein.Runtime.Repo` -- Ecto Repo configured for SQLite3 via `ecto_sqlite3`

```elixir
# Generate schema and migration from Skein type info
{:ok, schema_mod} = EctoSchema.build_schema("users", user_fields)
{:ok, migration_mod} = MigrationGen.build_migration("users", user_fields)
:ok = MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)

# Register and use
StoreEcto.register_schema("users", schema_mod)
StoreEcto.put("users", %{id: "u1", email: "alice@test.com", name: "Alice"}, caps)
```

### `Skein.Runtime.Memory`

Scoped key-value memory for Skein agents and modules. All namespaces share a single ETS table (`:skein_memory`) keyed by `{namespace, key}` -- namespaces are never separate tables. Called by compiled `memory.put`, `memory.get`, `memory.delete`, and `memory.list` effect calls.

**API:**

```elixir
Skein.Runtime.Memory.put("sessions", "key1", %{user: "alice"}, capabilities)
#=> {:ok, %{user: "alice"}}

Skein.Runtime.Memory.get("sessions", "key1", capabilities)
#=> {:ok, %{user: "alice"}}

Skein.Runtime.Memory.delete("sessions", "key1", capabilities)
#=> {:ok, "key1"}

Skein.Runtime.Memory.list("sessions", "user:", capabilities)
#=> ["user:alice", "user:bob"]
```

Every operation:
1. Validates `memory.kv` capability for the target namespace
2. Performs the ETS operation in the shared `:skein_memory` table, keyed by `{namespace, key}` (a single static table — namespace strings are never converted to atoms)
3. Records a trace span with timing and outcome via the unified EventStore
4. Each mutation (put/delete) also emits a `:state_change` event for audit and replay
5. Returns `{:ok, _}` or `{:error, _}`

Memory state can be reconstructed from the event stream:

```elixir
# Rebuild state from :state_change events (event-sourced)
Skein.Runtime.Memory.rebuild_from_events("sessions")
#=> %{"user_id" => "u-123", "session" => "s-456"}
```

### `Skein.Runtime.Llm`

Provider-agnostic LLM client. Provides unstructured chat, schema-constrained JSON, and streaming endpoints. Uses a pluggable backend system for testing and production.

**API:**

```elixir
Skein.Runtime.Llm.chat("claude-opus-4-8", "You are helpful", "What is 2+2?", capabilities)
#=> {:ok, "4"}

Skein.Runtime.Llm.json("claude-opus-4-8", "Evaluate refund", input, schema, capabilities)
#=> {:ok, %{"action" => "approve", "amount" => 100}}

Skein.Runtime.Llm.stream("claude-opus-4-8", "Be helpful", "Hello", on_chunk_fn, capabilities)
#=> {:ok, "Hello, world!"}  (chunks delivered to on_chunk_fn as they arrive)

Skein.Runtime.Llm.embed("voyage-3-large", "some text", capabilities)
#=> {:ok, [0.013, -0.027, ...]}  (vector dimensionality depends on the model)
```

Every operation:
1. Validates `model` capability for the requested model
2. Dispatches to the active backend (defaults to `TestBackend` for deterministic testing)
3. For `json/5`, parses the response as JSON and validates structure
4. For `stream/5`, delivers each chunk to the callback, then returns the assembled text
5. Records a trace span with model, timing, and outcome
6. Returns `{:ok, _}` or `{:error, <LlmError ABI tuple>}` — the frozen matchable form (C2/#297), e.g. `{:provider_error, code, message}`; internal `%Llm.Error{}` structs are converted at the public boundary

**Production backends** (selected via the `[llm]` profile in skein.toml):
- `Skein.Runtime.Llm.AnthropicBackend` -- Anthropic Messages API (the production default)
- `Skein.Runtime.Llm.OpenAiCompatibleBackend` -- any OpenAI-compatible `/chat/completions` server (local model servers, Voyage AI embeddings)
- `Skein.Runtime.Llm.BedrockBackend` -- Amazon Bedrock Converse API (SigV4-signed, with `model_map` remapping to Bedrock model IDs)

**Test backends:**
- `Skein.Runtime.Llm.TestBackend` -- deterministic responses for testing
- `Skein.Runtime.Llm.StreamingTestBackend` -- deterministic streaming chunks for testing
- `Skein.Runtime.Llm.FailingBackend` -- always returns errors (for error-path testing)
- `Skein.Runtime.Llm.FailingStreamBackend` -- always returns errors during streaming
- `Skein.Runtime.Llm.InvalidJsonBackend` -- returns invalid JSON (for parse-error testing)
- `Skein.Runtime.Llm.DynamicStreamBackend` -- configurable chunks via `{module, chunks}` tuple

Custom backends implement the `Skein.Runtime.Llm.Backend` behaviour.

**Error ABI (`LlmError`, C2/#297)** — what compiled Skein sees, matchable as `Err(LlmError.<Variant>(…))`:

| ABI form | Skein variant | Description |
|------|------|-------------|
| `{:parse_failed, raw, expected_type, parse_error}` | `ParseFailed` | Response couldn't be parsed as expected type |
| `{:refused, reason}` | `Refused` | LLM refused to generate a response |
| `{:rate_limit, retry_after_ms}` | `RateLimit` | Rate limited (retry-after in ms) |
| `{:timeout, elapsed_ms}` | `Timeout` | Request timed out |
| `{:content_filtered, filter}` | `ContentFiltered` | Response was filtered by content policy |
| `{:invalid_schema, violations}` | `InvalidSchema` | Response didn't match expected JSON schema |
| `{:provider_error, code, message}` | `ProviderError` | Provider returned an error |
| `{:denied, reason}` | `Denied` | Capability/scope denial |

Internally the backends use `Skein.Runtime.Llm.Error` structs; `Llm.Error.to_abi/1`
converts at the public boundary.

### `Skein.Runtime.Server`

A production-grade HTTP server powered by Bandit + Plug that serves compiled Skein handlers.

**API:**

```elixir
Skein.Runtime.Server.start_link(module: MyModule, port: 4000)
#=> {:ok, pid}
```

**Features:**
- Bandit HTTP server with concurrent request handling
- Plug-based router built dynamically from compiled handler metadata (`Skein.Runtime.Router`)
- Routes requests to handler functions via `Skein.Runtime.Handler`
- Serves trace data at `GET /__skein/traces`
- JSON response encoding with proper content-type headers
- Exception handling with 500 responses for handler errors

### `Skein.Runtime.Request`

Provides request body parsing and validation for `req.json[T]` expressions in handlers.

**API:**

```elixir
Skein.Runtime.Request.json(req_map, json_schema)
#=> {:ok, parsed_map} | {:error, reason}
```

**Features:**
- Parses JSON request body from the handler's `req` map
- Validates against compile-time JSON Schema derived from Skein type declarations
- Checks required fields and field types (string, integer, number, boolean, array, object)
- Returns structured error messages for validation failures

### `Skein.Runtime.EventStore`

Unified append-only event log for the entire runtime. All trace spans, user events (`event.log`), memory state changes, and annotations flow through a single ETS ordered set (`:skein_events`).

The in-memory log is size-bounded: once it grows past the configured maximum (`config :skein_runtime, :event_store_max_events`, default 100,000), the oldest events are evicted on append.

Durable persistence is **opt-in** ([#299](https://github.com/kormie/Skein/issues/299)): `Skein.Runtime.EventStore.Persistence.enable(db_path)` — which `skein run` calls by default, writing to `<project>/.skein/events.db` (`skein run --no-persist` opts out) — makes every ordinary append also write the event asynchronously to SQLite and reloads previously persisted events into the ETS log on startup, so a restarted service sees its history. ETS eviction never deletes persisted rows: SQLite keeps the full history beyond the in-memory bound. Persisted events round-trip through JSON, so a reloaded event is not bit-identical to the original (unknown keys and non-`kind`-like atom values come back as strings); the exact reloaded shape is pinned in the `Persistence` moduledoc and stays Pre-stable until the Wave F freeze. Without `enable/1` the log is in-memory only and nothing survives a restart.

**API:**

```elixir
# Append any event
Skein.Runtime.EventStore.append(%{kind: :http, method: :get, url: "/api"})
#=> :ok (auto-assigns id, timestamp, _key)

# Log a user event (compiled event.log() calls target this).
# The first argument is the stream label, threaded in by the compiler
# from the module's scoped capability event.log(stream) declaration
# (nil when the declaration is parameterless).
Skein.Runtime.EventStore.log(nil, "user.login", %{user: "alice"}, capabilities)
#=> {:ok, "user.login"} (Skein contract: Result[String, String] — a
#   scope-label denial is {:error, reason})

# Query by kind or any field
Skein.Runtime.EventStore.query(kind: :user_event)
Skein.Runtime.EventStore.query(kind: :state_change, namespace: "sessions")

# Recent events (newest first)
Skein.Runtime.EventStore.recent(10)

# Count events
Skein.Runtime.EventStore.count()
Skein.Runtime.EventStore.count(kind: :effect)

# Chronological snapshot for golden tests
Skein.Runtime.EventStore.snapshot()
#=> [oldest_event, ..., newest_event]

# Clear all events
Skein.Runtime.EventStore.clear()
```

**Event kinds:**

| Kind | Source | Description |
|------|--------|-------------|
| `:http`, `:memory`, `:llm`, `:store`, `:tool`, `:process`, `:timer` | Effect calls | Effect spans with timing, outcome, method |
| `:annotation` | `trace.annotate(key, value)` | Key-value markers |
| `:user_event` | `event.log(name, data)`, agent `emit` | User-defined structured events; agent emits carry `agent`/`instance_id`/`phase` tags |
| `:state_change` | `memory.put` / `memory.delete` | Memory mutation audit trail with key/value data |

Every event carries: `id` (unique hex), `timestamp` (monotonic microseconds), `kind`, and kind-specific fields.

### `Skein.Runtime.Trace`

Timing and instrumentation facade over `EventStore`. All effect wrappers (HTTP, Memory, LLM, etc.) call `Trace.with_span` to record spans with automatic timing.

**API:**

```elixir
# Execute a function with automatic tracing
Skein.Runtime.Trace.with_span(%{kind: :http, method: :get, url: url}, fn ->
  {:ok, result}
end)

# Add a trace annotation
Skein.Runtime.Trace.annotate("step", "analysis_complete")

# Query recent events (delegates to EventStore.recent)
Skein.Runtime.Trace.recent_spans(10)

# Record a span manually (delegates to EventStore.append)
Skein.Runtime.Trace.record_span(%{kind: :http, method: :get, url: "/test"})
```

`with_span/2` handles both normal returns and exceptions:
- `{:ok, _}` -> outcome `:ok`
- `{:error, _}` -> outcome `:error`
- Exception -> outcome `:error` with message, then re-raises

## How Compiled Code Uses the Runtime

The Skein code generator transforms effect calls into runtime calls:

```skein
-- Skein source:
http.get(url)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Http':'get'(Url, Capabilities)
```

```skein
-- Skein source:
store.users.get(id)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Store':'get'("users", Id, Capabilities)
```

```skein
-- Skein source:
memory.put("sessions", key, value)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Memory':'put'("sessions", Key, Value, Capabilities)
```

```skein
-- Skein source:
llm.chat("claude-opus-4-8", "system prompt", input)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Llm':'chat'("claude-opus-4-8", "system prompt", Input, Capabilities)
```

Where `Capabilities` is a literal list built from the module's `capability` declarations at compile time.

## Dependencies

The runtime manages its external dependencies carefully:

| Dependency | Purpose |
|-----------|---------|
| `:inets` (OTP) | HTTP client (`:httpc`) |
| `:ssl` (OTP) | HTTPS support |
| `jason` | JSON encoding/decoding |
| `bandit` | HTTP server |
| `plug` | Web framework |
| `ecto` | Database abstraction |
| `ecto_sql` | SQL adapter framework |
| `ecto_sqlite3` | SQLite3 adapter for local dev |

## Test Coverage

The runtime has comprehensive test coverage:
- **Property tests** (StreamData) covering capability host matching, wildcard behavior, URL extraction, store operations (ETS and Ecto), request validation, tool operations, LLM streaming, memory KV operations, queue dispatch, schedule cron parsing, and trace recording
- **Stateful property tests** (PropCheck) modeling memory, queue, schedule, and agent lifecycle as abstract state machines with random command sequences
- **Unit tests** covering agents, HTTP client, capability enforcement, handler dispatch, router, store operations (ETS and Ecto), Ecto schema generation, migration generation, memory, LLM client, Bandit HTTP server, queue dispatch, schedule dispatch, trace recording, and replay engine
