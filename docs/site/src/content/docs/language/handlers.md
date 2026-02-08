---
title: Handlers
description: HTTP, queue, and schedule handler syntax for building services in Skein.
---

## Overview

Handlers are the primary way Skein programs receive external input. They declare how a module responds to HTTP requests, queue messages, and scheduled events. Each handler type requires a corresponding capability declaration.

## Handler Types

Skein supports three handler types:

| Type | Capability | Trigger | Example |
|------|-----------|---------|---------|
| HTTP | `http.in` | Incoming HTTP request | `handler http GET "/users" (req) -> { ... }` |
| Queue | `queue.in` | Message from a named queue | `handler queue "events" (msg) -> { ... }` |
| Schedule | `schedule.in` | Cron-triggered timer | `handler schedule "*/5 * * * *" () -> { ... }` |

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
  capability queue.in

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
  capability schedule.in

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

## Mixed Handler Types

A module can declare handlers of multiple types. Each type requires its own capability:

```skein
module QueueWorker {
  capability http.in
  capability queue.in
  capability schedule.in

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
3. The `source` field distinguishes handler types: `:http`, `:queue`, `:schedule`

```elixir
# Example __handlers__/0 output for mixed types
[
  %{source: :http, method: :get, route: "/health", handler: :__handler_0__},
  %{source: :queue, method: nil, route: "jobs", handler: :__handler_1__},
  %{source: :schedule, method: nil, route: "*/5 * * * *", handler: :__handler_2__}
]
```

## Capability Requirements

The analyzer checks that each handler type has its required capability declared. Missing capabilities produce error `E0030`:

```
Error E0030: Capability 'queue.in' required but not declared.
Queue handlers require this capability.
Fix: capability queue.in
```
