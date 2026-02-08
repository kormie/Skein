---
title: Capabilities and Effects
description: How Skein enforces capability-based security for side effects like HTTP calls.
---

## Overview

Skein uses a **capability system** to control side effects. Any function that performs I/O -- HTTP requests, database access, file operations -- must be authorized by a capability declaration at the module level. This is checked at both compile time and runtime.

This design ensures:
- **Visibility:** You can see exactly what a module can do by reading its capability declarations
- **Security:** Modules cannot perform undeclared effects, even if code is injected
- **Auditability:** Every effect call is traced with timing and outcome

## Capability Declarations

Capabilities are declared at the top of a module with the `capability` keyword:

```skein
module UserService {
  capability http.out("api.example.com")
  capability http.out("auth.example.com")

  fn fetch_user(id: String) -> String {
    http.get("https://api.example.com/users/${id}")
  }
}
```

### Syntax

```skein
capability <namespace>.<kind>
capability <namespace>.<kind>(<params>)
```

### Available Capabilities

| Capability | Purpose | Parameters |
|------------|---------|------------|
| `http.out` | Outbound HTTP requests | Host allowlist (optional) |
| `http.in` | Inbound HTTP handlers | *(Phase 4)* |
| `store.table` | Database table access | Table name *(Phase 5)* |

More capabilities will be added in later phases (memory, LLM, tools, events).

### Wildcard Capabilities

A capability without parameters acts as a wildcard:

```skein
module OpenClient {
  capability http.out  -- allows HTTP to any host

  fn fetch(url: String) -> String {
    http.get(url)
  }
}
```

Use wildcard capabilities sparingly -- explicit host lists are preferred for security.

## Effect Calls

Effect calls look like regular function calls with a namespace prefix:

```skein
http.get(url)
http.post(url, body)
http.put(url, body)
http.patch(url, body)
http.delete(url)
```

### How They Parse

Effect calls use existing Skein syntax -- no special grammar is needed. `http.get(url)` parses as:

```
Call {
  target: FieldAccess {
    subject: Identifier { name: "http" },
    field: "get"
  },
  args: [Identifier { name: "url" }]
}
```

The analyzer recognizes this pattern and checks it against declared capabilities.

### Return Values

All HTTP effect calls return `Result[String, String]`:
- `{:ok, body}` on success (HTTP 2xx)
- `{:error, reason}` on failure (HTTP errors, network errors, capability violations)

## Compile-Time Checking

The analyzer's capability checking pass (Pass 3) walks every function body looking for effect calls. When it finds one, it checks that the module declares the required capability.

### Error: Missing Capability (E0030)

```skein
module BadService {
  fn fetch(url: String) -> String {
    http.get(url)  -- ERROR: E0030
  }
}
```

Produces:

```json
{
  "code": "E0030",
  "severity": "error",
  "message": "Capability 'http.out' required but not declared. Effect calls to 'http' require this capability.",
  "fix_hint": "Add a capability declaration to the module: capability http.out",
  "fix_code": "capability http.out"
}
```

The `fix_code` field gives agents the exact text to add to fix the error.

### What Gets Checked

The analyzer detects effect calls in all positions:
- Top-level expressions in function bodies
- Inside `let` bindings: `let result = http.get(url)`
- Inside `match` arms: `true -> http.get(url)`
- Inside pipe chains: `url |> http.get(url)`
- Nested within other expressions

## Runtime Enforcement

Even if the compiler is bypassed, the runtime enforces capabilities as a second layer of defense.

When compiled code calls `http.get(url)`, the code generator emits a call to `Skein.Runtime.Http.get(url, capabilities)` where `capabilities` is the module's declared capability list. The runtime checks the URL's host against this list before making the request.

```skein
-- This compiles, but the runtime blocks it:
-- The URL host "api.blocked.com" doesn't match "api.allowed.com"
module Service {
  capability http.out("api.allowed.com")

  fn fetch(url: String) -> String {
    http.get("https://api.blocked.com/data")
  }
}
```

### How It Works

1. The code generator embeds capabilities in each module via `__capabilities__/0`
2. Effect calls compile to runtime module calls with capabilities as a parameter
3. The runtime validates the URL host against declared hosts
4. Blocked requests return `{:error, "Host 'x' not declared in http.out capabilities"}`

## Trace Scaffolding

Every effect call is automatically traced. The runtime records:

| Field | Description |
|-------|-------------|
| `kind` | Effect type (`:http`) |
| `method` | Operation (`:get`, `:post`, etc.) |
| `url` | Target URL |
| `status` | HTTP status code (when available) |
| `duration_us` | Wall-clock duration in microseconds |
| `outcome` | `:ok` or `:error` |
| `timestamp` | Monotonic timestamp |

Traces are stored in an ETS table and can be queried via `Skein.Runtime.Trace.recent_spans/1`.

## How Modules Compile (with Capabilities)

A module with capabilities compiles to a BEAM module that includes:

1. All user-defined functions (as before)
2. `__info__/1` for Elixir compatibility (as before)
3. **`__capabilities__/0`** -- returns the declared capabilities as a list of maps

```elixir
# Calling __capabilities__/0 on a compiled module:
Skein.User.MyService.__capabilities__()
#=> [%{kind: "http.out", params: ["api.example.com"]}]
```

Effect calls in function bodies compile to remote calls:

```skein
-- Skein source
http.get(url)

-- Compiles to (conceptually):
Skein.Runtime.Http.get(url, [%{kind: "http.out", params: ["api.example.com"]}])
```
