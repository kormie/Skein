---
title: Supervisors
description: Declaring supervision trees for agent pools and crash recovery in Skein.
---

## Overview

Supervisor declarations describe groups of child processes and the crash-recovery strategies a host should apply to them, following the standard OTP supervision model. You declare supervisors alongside your other module-level constructs.

Today, supervisor declarations are **compile-time constructs**: the compiler parses and validates them (see [Analyzer Validation](#analyzer-validation)) and emits the tree as [`__supervisors__/0` metadata](#runtime-metadata) on the compiled module — the runtime does not yet start OTP supervision trees from these declarations. The declaration surface itself is frozen (spec §3.9); wiring it into real supervision under `skein run` is tracked by [#325](https://github.com/kormie/Skein/issues/325). Until that lands, materializing the tree (e.g. mapping it onto `Supervisor.start_link/2`) is the host application's job, and the behavior tables below document the *declared semantics* a host that honors the metadata applies.

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

**Restart policies (declared semantics):**

| Policy | Declared behavior |
|--------|-------------------|
| `permanent` | Always restarted when it exits |
| `transient` | Restarted only on abnormal exit |
| `temporary` | Never restarted |

## Strategy

The `strategy:` directive declares how sibling children are affected when one crashes:

```skein
supervisor Main {
  child DbPool
  child HttpServer
  strategy: one_for_one
}
```

| Strategy | Declared behavior |
|----------|-------------------|
| `one_for_one` | Only the crashed child is restarted |
| `one_for_all` | All children are restarted when one crashes |
| `rest_for_one` | The crashed child and all children started after it are restarted |

If omitted, `one_for_one` is the default.

## Max Restarts

The `max_restarts:` directive declares a crash intensity limit: more than `count` restarts within `period` seconds should shut down the supervisor itself.

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

The `__supervisors__/0` metadata function is the supervisor declaration's compiled artifact — the [stability policy](/Skein/reference/stability/) classifies it as compiled-module metadata. Modules with supervisors expose it, returning the supervisor tree:

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
