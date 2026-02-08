---
title: Supervisors
description: Declaring supervision trees for agent pools and crash recovery in Skein.
---

## Overview

Supervisors manage groups of child processes and define crash-recovery strategies. They are the standard OTP mechanism for building fault-tolerant systems. In Skein, you declare supervisors alongside your other module-level constructs.

## Syntax

```
supervisor Name {
  child Target
  child Target(Arg) { key: value }
  strategy: one_for_one | one_for_all | rest_for_one
  max_restarts: count per period_seconds
}
```

All directives are optional except that a supervisor should have at least one `child` (the analyzer will warn otherwise).

## Children

Each `child` directive names a target module to supervise:

```skein
module MyService {
  supervisor Main {
    child HttpServer
    child Worker
  }
}
```

### Child Arguments

Children can take arguments to parameterize them:

```skein
supervisor AgentSupervisor {
  child AgentPool(RefundAgent)
  child AgentPool(TriageAgent)
}
```

### Child Options

Children accept options in a `{ key: value }` block:

```skein
supervisor Main {
  child HttpServer { restart: permanent }
  child AgentPool(RefundAgent) { max: 5000, restart: transient }
  child BatchWorker { restart: temporary }
}
```

**Restart policies:**

| Policy | Behavior |
|--------|----------|
| `permanent` | Always restarted when it exits |
| `transient` | Restarted only on abnormal exit |
| `temporary` | Never restarted |

## Strategy

The `strategy:` directive controls how sibling children are affected when one crashes:

```skein
supervisor Main {
  child DbPool
  child HttpServer
  strategy: one_for_one
}
```

| Strategy | Behavior |
|----------|----------|
| `one_for_one` | Only the crashed child is restarted |
| `one_for_all` | All children are restarted when one crashes |
| `rest_for_one` | The crashed child and all children started after it are restarted |

If omitted, `one_for_one` is the default.

## Max Restarts

The `max_restarts:` directive sets a crash intensity limit. If more than `count` restarts happen within `period` seconds, the supervisor itself shuts down:

```skein
supervisor Main {
  child Worker
  max_restarts: 10 per 60s
}
```

This means: at most 10 restarts in any 60-second window.

## Full Example

```skein
module RefundService {
  supervisor Main {
    child HttpServer { restart: permanent }
    child AgentPool(RefundAgent) { max: 5000, restart: transient }
    strategy: one_for_one
    max_restarts: 10 per 60s
  }
}
```

## Runtime Metadata

Compiled modules with supervisors expose a `__supervisors__/0` function that returns the supervisor tree metadata:

```elixir
mod.__supervisors__()
# => [
#   %{
#     name: "Main",
#     strategy: :one_for_one,
#     max_restarts: {10, 60},
#     children: [
#       %{target: "HttpServer", args: [], options: %{restart: "permanent"}},
#       %{target: "AgentPool", args: ["RefundAgent"], options: %{max: 5000, restart: "transient"}}
#     ]
#   }
# ]
```

## Analyzer Validation

The analyzer checks supervisor declarations and produces errors/warnings:

| Code | Severity | Description |
|------|----------|-------------|
| E0040 | error | Invalid strategy value |
| E0041 | error | Invalid max_restarts format |
| E0042 | warning | Supervisor has no children |
