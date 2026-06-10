---
title: Handlers
description: HTTP, queue, and schedule handler syntax for building services in Skein.
---

## Overview

Handlers are the primary way Skein programs receive external input. They declare how a module responds to HTTP requests, queue messages, and scheduled events. Each handler type requires a corresponding capability declaration.

## Handler Types

Skein supports four handler types:

| Type | Capability | Trigger | Example |
|------|-----------|---------|---------|
| HTTP | `http.in` | Incoming HTTP request | `handler http GET "/users" (req) -> { ... }` |
| Queue | `queue.consume` | Message from a named queue | `handler queue "events" (msg) -> { ... }` |
| Topic | `topic.consume` | Broadcast message from a named topic | `handler topic "order.events" (msg) -> { ... }` |
| Schedule | `schedule.trigger` | Cron-triggered timer | `handler schedule "*/5 * * * *" () -> { ... }` |

## HTTP Handlers

HTTP handlers respond to incoming HTTP requests. They specify an HTTP method, a route pattern, and receive a request map.

### Syntax

```skein
handler http METHOD "route" (param) -> {
  -- body
}
```

- **METHOD**: One of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`
- **route**: A string path, optionally with `:param` segments for path parameters
- **param**: The name bound to the request map

### Request Map

The handler parameter receives a map with:

| Field | Type | Description |
|-------|------|-------------|
| `params` | Map | Path parameters extracted from the route |
| `headers` | Map | Request headers |
| `body` | String | Raw request body |
| `method` | Atom | HTTP method (`:get`, `:post`, etc.) |
| `path` | String | Request path |

### Example

```skein
module UserService {
  capability http.in

  handler http GET "/users/:id" (req) -> {
    let id = req.params.id
    respond.json(200, id)
  }

  handler http POST "/users" (req) -> {
    respond.json(201, "created")
  }
}
```

### Request Body Validation

Use `req.json[T]` to parse and validate JSON request bodies against a declared type:

```skein
module OrderService {
  capability http.in

  type CreateOrder {
    product_id: String
    quantity: Int @min(1)
  }

  handler http POST "/orders" (req) -> {
    let order = req.json[CreateOrder]
    respond.json(201, "ok")
  }
}
```

## Queue Handlers

Queue handlers process messages from named message queues. They are triggered asynchronously when a message is published to the subscribed queue.

### Syntax

```skein
handler queue "queue-name" (param) -> {
  -- body
}
```

- **queue-name**: A string identifying the queue to subscribe to
- **param**: The name bound to the message map

### Example

```skein
module OrderWorker {
  capability queue.consume

  handler queue "order-events" (msg) -> {
    let data = msg
    respond.json(200, "processed")
  }

  handler queue "priority-events" (msg) -> {
    respond.json(200, "priority-processed")
  }
}
```

### Runtime Behavior

At startup, queue handlers are registered with `Skein.Runtime.Queue`. Messages published to the queue are dispatched to the handler function asynchronously. Messages are delivered in order within a single queue.

## Schedule Handlers

Schedule handlers run on a cron-based schedule. They take no input parameters and execute periodically.

### Syntax

```skein
handler schedule "cron-expression" () -> {
  -- body
}
```

- **cron-expression**: A standard 5-field cron expression (`minute hour day month weekday`)

### Cron Expression Examples

| Expression | Meaning |
|-----------|---------|
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour on the hour |
| `0 0 * * *` | Daily at midnight |
| `0 9 * * 1` | Every Monday at 9:00 AM |
| `30 8 1 * *` | 8:30 AM on the 1st of each month |

### Example

```skein
module Maintenance {
  capability schedule.trigger

  handler schedule "*/5 * * * *" () -> {
    respond.json(200, "cleanup")
  }

  handler schedule "0 0 * * *" () -> {
    respond.json(200, "daily-report")
  }
}
```

### Runtime Behavior

At startup, schedule handlers are registered with `Skein.Runtime.Schedule`. The runtime triggers handlers at the appropriate times. For testing, handlers can be triggered manually with `Skein.Runtime.Schedule.trigger/1`.

## Topic Handlers

Topic handlers subscribe to named topics and receive every message published to that topic. Unlike queue handlers (which deliver each message to a single consumer), topic handlers use **fan-out semantics**: every subscriber receives every message.

### Syntax

```skein
handler topic "topic-name" (param) -> {
  -- body
}
```

- **topic-name**: A string identifier for the topic (e.g., `"order.events"`)
- **param**: The message parameter name, bound to the published data

### Example

```skein
module PubsubNotifications {
  capability topic.consume("order.events")
  capability topic.publish("order.events")

  -- Email notification: receives every order event
  handler topic "order.events" (msg) -> {
    let event = msg
    respond.json(200, "email-sent")
  }

  -- Analytics: also receives every order event (fan-out)
  handler topic "order.events" (msg) -> {
    let event = msg
    respond.json(200, "analytics-recorded")
  }
}
```

### Topic vs Queue

| | Queue | Topic |
|---|-------|-------|
| Delivery | Single consumer | All subscribers (fan-out) |
| Capability | `queue.consume` | `topic.consume` |
| Use case | Job processing | Notifications, events |
| Publish | `queue.publish(name, data)` | `topic.publish(name, data)` |

### Runtime Behavior

At startup, topic handlers are registered with `Skein.Runtime.Topic`. Messages published via `topic.publish(name, data)` are dispatched asynchronously to ALL subscribers. Messages are delivered in order within each subscriber.

## Mixed Handler Types

A module can declare handlers of multiple types. Each type requires its own capability:

```skein
module QueueWorker {
  capability http.in
  capability queue.consume
  capability schedule.trigger

  handler http GET "/health" (req) -> {
    respond.json(200, "ok")
  }

  handler queue "jobs" (msg) -> {
    respond.json(200, "processed")
  }

  handler schedule "*/5 * * * *" () -> {
    respond.json(200, "cleanup")
  }
}
```

## Compilation

All handler types compile to the same pattern:

1. Each handler becomes a `__handler_N__/1` function in the compiled module
2. Handler metadata is returned by `__handlers__/0` with fields: `source`, `method`, `route`, `handler`
3. The `source` field distinguishes handler types: `:http`, `:queue`, `:topic`, `:schedule`

```elixir
# Example __handlers__/0 output for mixed types
[
  %{source: :http, method: :get, route: "/health", handler: :__handler_0__},
  %{source: :queue, method: nil, route: "jobs", handler: :__handler_1__},
  %{source: :schedule, method: nil, route: "*/5 * * * *", handler: :__handler_2__}
]
```

## Response Helpers

Handlers return responses using one of three built-in helpers. Each sets the appropriate HTTP `Content-Type` header automatically.

| Helper | Content-Type | Use When |
|--------|-------------|----------|
| `respond.json(status, body)` | `application/json` | Returning structured data (maps, lists, values) |
| `respond.text(status, body)` | `text/plain` | Returning plain text (health checks, simple strings) |
| `respond.html(status, body)` | `text/html` | Returning HTML pages or fragments |

### Examples

```skein
module HelloHttp {
  capability http.in

  -- JSON API endpoint
  handler http GET "/api/users" (req) -> {
    respond.json(200, "users")
  }

  -- Plain text health check
  handler http GET "/health" (req) -> {
    respond.text(200, "ok")
  }

  -- HTML page
  handler http GET "/page" (req) -> {
    respond.html(200, "<h1>Hello from Skein</h1>")
  }
}
```

All three helpers take two arguments:
- **status**: An integer HTTP status code (e.g., `200`, `201`, `404`, `500`)
- **body**: A string value to send as the response body

For `respond.json`, the body is JSON-encoded before sending. For `respond.text` and `respond.html`, the body string is sent as-is.

## Idempotent Handlers

The `idempotent(key)` guard prevents duplicate processing of messages. Place it at the top of a handler body — if the key has already been processed, the handler skips execution silently.

```skein
module BillingWorker {
  capability queue.consume

  handler queue "billing.events" (msg) -> {
    idempotent(msg.id)

    -- This code only runs once per unique msg.id
    let amount = msg.body
    respond.json(200, amount)
  }
}
```

**How it works:**

1. On first call with a given key, `idempotent()` records the key and continues execution
2. On subsequent calls with the same key, the handler is skipped entirely
3. Keys expire after a configurable TTL (default: 1 hour), allowing reprocessing after expiry

**Constraints:**

- `idempotent()` can only be used inside handler bodies (not in regular functions or agent handlers). Using it elsewhere produces error `E0035`.
- The key argument must be a `String` expression.

**Dispatch behavior on skip:**

| Handler Type | Skip Response |
|-------------|--------------|
| HTTP | Returns `200 "already processed"` |
| Queue | Silently drops the message |
| Topic | Silently drops the message |
| Schedule | Silently skips the invocation |

## Capability Requirements

The analyzer checks that each handler type has its required capability declared. Missing capabilities produce error `E0012`:

```
Error E0012: Capability 'queue.consume' required but not declared.
Queue handlers require this capability.
Fix: capability queue.consume
```
