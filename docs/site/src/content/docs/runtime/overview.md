---
title: Runtime
description: The Skein runtime library -- agents, HTTP client, handler dispatch, store, memory, LLM client, capability enforcement, trace recording, and HTTP server.
---

## Overview

The Skein runtime (`skein_runtime`) provides the libraries that compiled Skein code calls at execution time. It handles:

- **Agent runtime** -- GenStateMachine-based state machines for Skein agents via `Skein.Runtime.Agent`
- **HTTP client** -- making outbound HTTP requests via `Skein.Runtime.Http`
- **Capability enforcement** -- validating effect calls against declared capabilities
- **Handler dispatch** -- routing HTTP requests to compiled handler functions
- **Store** -- ETS-backed key-value storage with capability enforcement
- **Memory** -- scoped KV storage with namespace isolation via `Skein.Runtime.Memory`
- **LLM client** -- provider-agnostic LLM calls with schema-constrained JSON via `Skein.Runtime.Llm`
- **HTTP server** -- lightweight TCP server for serving Skein handlers
- **Trace recording** -- capturing timing, metadata, and outcomes for every effect call

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

Skein.Runtime.Agent.get_state(pid)
#=> %{request_id: "abc", amount: 100}

Skein.Runtime.Agent.get_events(pid)
#=> [%{type: "refund_approved", amount: 100}]
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
Skein.Runtime.Handler.dispatch(method, path, headers, body, module)
#=> {:ok, %{status: 200, body: response_json}} | {:error, reason}
```

**Features:**
- Route matching with path parameters (`:id` syntax)
- HTTP method dispatching (GET, POST, PUT, PATCH, DELETE)
- Request map construction with `params`, `headers`, `body`, `method`, `path`
- JSON response encoding via Jason
- Trace span recording for each dispatched request

### `Skein.Runtime.Store`

ETS-backed key-value storage that compiled `store.table` effect calls target.

**API:**

```elixir
Skein.Runtime.Store.get(table, id, capabilities)
#=> {:ok, record} | {:error, "not_found"}

Skein.Runtime.Store.put(table, record, capabilities)
#=> {:ok, record}

Skein.Runtime.Store.delete(table, id, capabilities)
#=> {:ok, id}

Skein.Runtime.Store.query(table, filter_fn, capabilities)
#=> {:ok, [records]}
```

Every operation:
1. Validates `store.table` capability for the target table
2. Performs the ETS operation
3. Records a trace span with timing and outcome
4. Returns the result as an `{:ok, _}` or `{:error, _}` tuple

### `Skein.Runtime.Memory`

Scoped key-value memory for Skein agents and modules. Each namespace gets a separate ETS table. Called by compiled `memory.put`, `memory.get`, `memory.delete`, and `memory.list` effect calls.

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
2. Performs the ETS operation in the namespace-specific table (`skein_memory_<namespace>`)
3. Records a trace span with timing and outcome
4. Returns `{:ok, _}` or `{:error, _}`

### `Skein.Runtime.Llm`

Provider-agnostic LLM client. Provides unstructured chat and schema-constrained JSON endpoints. Uses a pluggable backend system for testing and production.

**API:**

```elixir
Skein.Runtime.Llm.chat("claude-3-5-sonnet", "You are helpful", "What is 2+2?", capabilities)
#=> {:ok, "4"}

Skein.Runtime.Llm.json("claude-3-5-sonnet", "Evaluate refund", input, schema, capabilities)
#=> {:ok, %{"action" => "approve", "amount" => 100}}
```

Every operation:
1. Validates `model` capability for the requested model
2. Dispatches to the active backend (defaults to `TestBackend` for deterministic testing)
3. For `json/5`, parses the response as JSON and validates structure
4. Records a trace span with model, timing, and outcome
5. Returns `{:ok, _}` or `{:error, %Llm.Error{}}`

**Backends:**
- `Skein.Runtime.Llm.TestBackend` -- deterministic responses for testing
- `Skein.Runtime.Llm.FailingBackend` -- always returns errors (for error-path testing)
- `Skein.Runtime.Llm.InvalidJsonBackend` -- returns invalid JSON (for parse-error testing)
- Custom backends implement the `Skein.Runtime.Llm.Backend` behaviour

**Error types (`Skein.Runtime.Llm.Error`):**

| Kind | Description |
|------|-------------|
| `:parse_failed` | Response couldn't be parsed as expected type |
| `:refused` | LLM refused to generate a response |
| `:rate_limit` | Rate limited (includes retry-after duration) |
| `:timeout` | Request timed out |
| `:content_filtered` | Response was filtered by content policy |
| `:invalid_schema` | Response didn't match expected JSON schema |
| `:provider_error` | Provider returned an error |
| `:capability_error` | Missing capability declaration |

### `Skein.Runtime.Server`

A lightweight GenServer-based TCP server that serves compiled Skein handlers over HTTP.

**API:**

```elixir
Skein.Runtime.Server.start_link(module, port: 4000)
#=> {:ok, pid}
```

**Features:**
- Port binding and connection acceptance loop
- HTTP request parsing via Erlang `:gen_tcp`
- Routes requests to handler functions via `Skein.Runtime.Handler`
- Serves trace data at `GET /__skein/traces`
- JSON response streaming

### `Skein.Runtime.Trace`

Records trace spans for every effect call. Uses an ETS ordered set for storage.

**API:**

```elixir
# Record a span manually
Skein.Runtime.Trace.record_span(%{
  kind: :http,
  method: :get,
  url: "https://api.example.com/data",
  status: 200,
  duration_us: 1500,
  outcome: :ok
})

# Execute a function with automatic tracing
Skein.Runtime.Trace.with_span(%{kind: :http, method: :get, url: url}, fn ->
  # ... do work ...
  {:ok, result}
end)

# Query recent spans
Skein.Runtime.Trace.recent_spans(10)
#=> [%{kind: :http, method: :get, url: ..., duration_us: ..., ...}, ...]

# Clear all recorded spans
Skein.Runtime.Trace.clear()
```

**Span fields:**

| Field | Type | Description |
|-------|------|-------------|
| `kind` | atom | Effect type (`:http`, `:store`, `:memory`, `:llm`) |
| `method` | atom | Operation (`:get`, `:post`, `:put`, `:delete`, `:query`, `:chat`, `:json`, `:list`) |
| `url` | string | Target URL (HTTP) or table name (store) |
| `namespace` | string | Memory namespace (memory operations) |
| `model` | string | LLM model identifier (LLM operations) |
| `status` | integer | HTTP status code (when available) |
| `duration_us` | integer | Wall-clock duration in microseconds |
| `outcome` | atom | `:ok` or `:error` |
| `error` | string | Error message (on exception) |
| `timestamp` | integer | Monotonic timestamp (for ordering) |

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
llm.chat("claude-3-5-sonnet", "system prompt", input)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Llm':'chat'("claude-3-5-sonnet", "system prompt", Input, Capabilities)
```

Where `Capabilities` is a literal list built from the module's `capability` declarations at compile time.

## Dependencies

The runtime minimizes external dependencies:

| Dependency | Purpose |
|-----------|---------|
| `:inets` (OTP) | HTTP client (`:httpc`) |
| `:ssl` (OTP) | HTTPS support |
| `jason` | JSON encoding/decoding |

No third-party HTTP libraries are required. This keeps the runtime lightweight and avoids transitive dependency issues.

## Test Coverage

The runtime has comprehensive test coverage:
- **10 property tests** covering capability host matching, wildcard behavior, URL extraction, and store operations
- **124 unit tests** covering agents, HTTP client, capability enforcement, handler dispatch, store operations, memory, LLM client, HTTP server, and trace recording
