---
title: Capabilities and Effects
description: How Skein enforces capability-based security for side effects like HTTP calls and store operations.
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
| `http.in` | Inbound HTTP handlers | Route prefix (optional) |
| `store.table` | Database table access | Table name |
| `memory.kv` | Scoped KV memory | Namespace name |
| `model` | LLM model access | Provider, model identifier |
| `tool.use` | Tool execution | Tool name |
| `queue.in` | Inbound queue handlers | Queue name (optional) |
| `topic.publish` | Publish to a named topic | Topic name |
| `topic.consume` | Subscribe to a named topic | Topic name |
| `schedule.in` | Cron-based schedule handlers | Cron expression (optional) |
| `trace` | Trace annotation | None |

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

Effect calls look like regular function calls with a namespace prefix.

### HTTP Effects

```skein
http.get(url)
http.post(url, body)
http.put(url, body)
http.patch(url, body)
http.delete(url)
```

### Store Effects

```skein
store.users.get(id)
store.users.put(record)
store.users.delete(id)
store.users.query(filter)
```

### Memory Effects

```skein
memory.put("sessions", key, value)
memory.get("sessions", key)
memory.delete("sessions", key)
memory.list("sessions", prefix)
```

Memory is scoped by namespace. Each namespace requires a `capability memory.kv("namespace")` declaration.

### LLM Effects

```skein
llm.chat("claude-sonnet-4-5", "system prompt", input)
llm.json[RefundDecision]("claude-sonnet-4-5", "system prompt", input)
llm.stream("claude-sonnet-4-5", "system prompt", input)
```

`llm.chat` returns unstructured text. `llm.json[T]` returns a parsed map constrained by a JSON schema derived from type `T` at compile time. `llm.stream` returns the assembled response text after streaming all chunks. All three require a `capability model(...)` declaration.

#### Type-Parameterized JSON (`llm.json[T]`)

The `llm.json[T]` syntax takes a type parameter in square brackets. The compiler looks up the type declaration and generates the corresponding JSON Schema, which is passed to the LLM runtime for schema-constrained decoding:

```skein
module RefundService {
  type RefundDecision {
    action: String @one_of(["approve", "deny", "escalate"])
    amount: Int @min(0)
    reason: String
  }

  capability model("anthropic", "claude-sonnet-4-5")

  fn decide(ticket: String) -> String {
    llm.json[RefundDecision]("claude-sonnet-4-5", "Decide if this warrants a refund.", ticket)
  }
}
```

The generated schema for `RefundDecision` includes all type information and constraint annotations:

```json
{
  "type": "object",
  "properties": {
    "action": { "type": "string", "enum": ["approve", "deny", "escalate"] },
    "amount": { "type": "integer", "minimum": 0 },
    "reason": { "type": "string" }
  },
  "required": ["action", "amount", "reason"]
}
```

You can also call `llm.json` without a type parameter for untyped JSON responses:

```skein
llm.json("claude-sonnet-4-5", "Return JSON.", input)
```

This uses an empty schema (`{}`) which accepts any valid JSON.

### Request Body Validation (`req.json[T]`)

Inside HTTP handlers, `req.json[T]` parses the request body as JSON and validates it against the schema derived from type `T`:

```skein
module UserService {
  capability http.in

  type CreateUser {
    email: String
    name: String
  }

  handler http POST "/users" (req) -> {
    let user = req.json[CreateUser]!
    respond.json(201, user)
  }
}
```

The compiler generates a JSON Schema from `CreateUser` at compile time. At runtime, `req.json[T]` parses the request body and validates the required fields and types. It returns `{:ok, parsed}` or `{:error, reason}`, making it compatible with the `!` (crash) and `?` (propagate) unwrap operators.

### Tool Effects

```skein
tool.call(CreateRefund, args)
tool.list()
tool.schema(CreateRefund)
```

Tool effects require a `capability tool.use(ToolName)` declaration. See the [Tools](/Skein/language/tools/) page for full documentation on tool declarations and calling.

### Topics

Topics provide pub/sub messaging with fan-out delivery. Every subscriber to a topic receives every published message.

```skein
-- Publishing requires topic.publish capability
capability topic.publish("order.events")

topic.publish("order.events", data)
```

The `topic.publish(name, data)` effect publishes `data` to all handlers subscribed to the named topic. Unlike queues (which deliver to a single consumer), topics broadcast to every subscriber.

To consume from a topic, declare a `topic.consume` capability and a `handler topic` block:

```skein
capability topic.consume("order.events")

handler topic "order.events" (msg) -> {
  -- Every subscriber receives every message
  respond.json(200, "processed")
}
```

See the [Handlers](/Skein/language/handlers/) page for full topic handler documentation.

### Trace

The `trace.annotate(key, value)` effect adds key-value metadata to the current trace span. This is useful for enriching traces with business context.

```skein
capability trace

fn process_order(order_id: String) -> String {
  trace.annotate("order_id", order_id)
  -- ... processing logic ...
}
```

Annotations are attached to the enclosing span (recorded by `with_span`). In HTTP handlers, annotations appear on the HTTP span:

```skein
module OrderService {
  capability http.in
  capability trace

  handler http POST "/orders" (req) -> {
    trace.annotate("endpoint", "/orders")
    trace.annotate("method", "POST")
    respond.json(200, "created")
  }
}
```

In agents, annotations enrich phase-handling spans with business context:

```skein
agent RefundAgent {
  capability model("gpt-4")
  capability memory.kv
  capability trace

  -- ...

  on phase(Phase.Review) -> {
    let order = memory.get("order_id")
    trace.annotate("ticket_id", order)
    let decision = llm.chat("gpt-4", "Evaluate refund", order)
    trace.annotate("decision", decision)
    -- ...
  }
}
```

Annotations appear in the `/__skein/traces` debug endpoint alongside timing and outcome data.

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

**HTTP** effect calls return `Result[String, String]`:
- `{:ok, body}` on success (HTTP 2xx)
- `{:error, reason}` on failure (HTTP errors, network errors, capability violations)

**Memory** effect calls return `Result` tuples:
- `memory.get` returns `{:ok, value}` or `{:error, "not_found"}`
- `memory.put` returns `{:ok, value}`
- `memory.delete` returns `{:ok, key}`
- `memory.list` returns a list of matching keys

**LLM** effect calls return `Result` tuples:
- `llm.chat` returns `{:ok, response_text}` or `{:error, %Llm.Error{}}`
- `llm.json` returns `{:ok, parsed_map}` or `{:error, %Llm.Error{}}`
- `llm.stream` returns `{:ok, assembled_text}` or `{:error, %Llm.Error{}}` (chunks delivered via callback at runtime)

## Compile-Time Checking

The analyzer's capability checking pass (Pass 3) walks every function body looking for effect calls. When it finds one, it checks that the module declares the required capability.

### Error: Missing Capability (E0012)

```skein
module BadService {
  fn fetch(url: String) -> String {
    http.get(url)  -- ERROR: E0012
  }
}
```

Produces:

```json
{
  "code": "E0012",
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

## Effect Tracing

Every effect call is automatically traced. The runtime records:

| Field | Description |
|-------|-------------|
| `kind` | Effect type (`:http`, `:memory`, `:llm`, `:store`, `:tool`) |
| `method` | Operation (`:get`, `:post`, `:put`, `:chat`, `:json`, `:call`, etc.) |
| `url` | Target URL (HTTP) |
| `namespace` | Memory namespace (Memory) |
| `model` | LLM model name (LLM) |
| `name` | Tool name (Tool) |
| `duration_us` | Wall-clock duration in microseconds |
| `outcome` | `:ok` or `:error` |
| `timestamp` | Monotonic timestamp |
| `annotations` | Key-value metadata added via `trace.annotate()` |

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

## Idempotency

The `idempotent(key)` expression is a built-in guard for handler bodies that ensures exactly-once processing. It does not require a capability declaration — it is available in any handler.

```skein
handler queue "events" (msg) -> {
  idempotent(msg.id)
  -- rest of handler only runs once per unique msg.id
}
```

The idempotency guard is backed by `Skein.Runtime.Idempotent`, which tracks processed keys in an ETS table with a configurable TTL (default: 1 hour). See the [Handlers](/language/handlers/#idempotent-handlers) page for full details.
