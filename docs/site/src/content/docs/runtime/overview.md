---
title: Runtime
description: The Skein runtime library — HTTP client, capability enforcement, and trace recording.
---

## Overview

The Skein runtime (`skein_runtime`) provides the libraries that compiled Skein code calls at execution time. It handles:

- **HTTP client** -- making outbound HTTP requests via `Skein.Runtime.Http`
- **Capability enforcement** -- validating effect calls against declared capabilities
- **Trace recording** -- capturing timing, metadata, and outcomes for every effect call

The runtime is an OTP application that starts automatically when Skein code is loaded.

## Runtime Modules

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
| `kind` | atom | Effect type (`:http`) |
| `method` | atom | Operation (`:get`, `:post`, etc.) |
| `url` | string | Target URL |
| `status` | integer | HTTP status code (when available) |
| `duration_us` | integer | Wall-clock duration in microseconds |
| `outcome` | atom | `:ok` or `:error` |
| `error` | string | Error message (on exception) |
| `timestamp` | integer | Monotonic timestamp (for ordering) |

`with_span/2` handles both normal returns and exceptions:
- `{:ok, _}` → outcome `:ok`
- `{:error, _}` → outcome `:error`
- Exception → outcome `:error` with message, then re-raises

## How Compiled Code Uses the Runtime

The Skein code generator transforms effect calls into runtime calls:

```
-- Skein source:
http.get(url)

-- Compiles to (Core Erlang):
call 'Elixir.Skein.Runtime.Http':'get'(Url, Capabilities)
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
- **5 property tests** covering capability host matching, wildcard behavior, URL extraction
- **31 unit tests** covering HTTP capability enforcement, trace recording, and span querying
