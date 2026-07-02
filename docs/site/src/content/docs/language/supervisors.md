---
title: Supervisors
description: Declaring supervision trees for agent pools and crash recovery in Skein.
---

## Overview

Supervisor declarations describe groups of child agents and the crash-recovery strategies applied to them, following the standard OTP supervision model. You declare supervisors alongside your other module-level constructs.

Supervisor declarations are **real supervision** ([#325](https://github.com/kormie/Skein/issues/325)): the compiler validates them (see [Analyzer Validation](#analyzer-validation)) and emits the tree as [`__supervisors__/0` metadata](#runtime-metadata), and `skein run` boots one OTP supervisor per declaration for as long as the service runs. A crashed child is restarted per the declared strategy, every (re)start appends a `:supervisor`/`:child_started` event to the event log, and `memory.kv` data survives child restarts — the store outlives agent processes.

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

Each `child` directive names an agent in the same module to supervise:

```skein
module MyService {
  supervisor Main {
    child Worker
  }

  agent Worker {
    enum Phase {
      Waiting -> []
    }

    on start() -> {
      transition(Phase.Waiting)
    }

    on phase(Phase.Waiting) -> {
      0
    }
  }
}
```

At boot, each `child` target resolves to the module's compiled nested agent (`Skein.Agent.<Module>.<Target>`). A child whose target does not resolve to an agent in the module is skipped with a `:supervisor`/`:child_skipped` event rather than failing the boot.

### Child Arguments

The named entries in a child's `{ key: value }` block (other than `restart:`) are the agent's start arguments — they become the argument map passed to the agent's `on start(...)` handler:

```skein
supervisor Pool {
  child Worker { n: 5 }
}
```

starts `Worker` with `n = 5` in its `on start(n: Int)` handler. Parenthesized arguments (`child AgentPool(RefundAgent)`) distinguish child declarations but are not passed to the agent's start handler.

### Restart Policies

The `restart:` option in a child's block selects the OTP restart policy:

```skein
supervisor Main {
  child Worker { restart: permanent }
  child BatchWorker { restart: transient }
  child OneShot { restart: temporary }
}
```

| Policy | Behavior |
|--------|----------|
| `permanent` | Always restarted when it exits (the default) |
| `transient` | Restarted only on abnormal exit |
| `temporary` | Never restarted |

## Strategy

The `strategy:` directive declares how sibling children are affected when one crashes:

```skein
supervisor Main {
  child Worker
  child Watcher
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

The `max_restarts:` directive is the OTP crash intensity limit: more than `count` restarts within `period` seconds shuts down the supervisor itself.

```skein
supervisor Main {
  child Worker
  max_restarts: 10 per 60s
}
```

This means: at most 10 restarts in any 60-second window. When omitted, the OTP defaults apply.

## Restarts in the Trace

Every child start appends a `:supervisor` event to the unified event log — and because restarts re-run the child start, restart #2+ show up as additional `:child_started` events:

```elixir
Skein.Runtime.EventStore.query(kind: :supervisor, event: :child_started)
# => one event per start, including each restart:
# %{kind: :supervisor, event: :child_started, supervisor: "Main", child: "Worker", ...}
```

Agent `memory.kv` writes survive these restarts: the memory table is owned by the supervised runtime, not the agent process, so data written before a crash is still readable after the supervisor brings the child back.

## Full Example

```skein
module RefundService {
  supervisor Main {
    child RefundWorker { restart: permanent }
    strategy: one_for_one
    max_restarts: 10 per 60s
  }

  agent RefundWorker {
    capability memory.kv

    enum Phase {
      Waiting -> []
    }

    on start() -> {
      memory.put("started", "true")
      transition(Phase.Waiting)
    }

    on phase(Phase.Waiting) -> {
      0
    }
  }
}
```

## Runtime Metadata

The `__supervisors__/0` metadata function is the supervisor declaration's compiled artifact — the [stability policy](/Skein/reference/stability/) classifies it as compiled-module metadata. It is what `skein run` (via `Skein.Runtime.SupervisorHost`) realizes as OTP supervision. Modules with supervisors expose it, returning the supervisor tree:

```elixir
mod.__supervisors__()
# => [
#   %{
#     name: "Main",
#     strategy: :one_for_one,
#     max_restarts: {10, 60},
#     children: [
#       %{target: "RefundWorker", args: [], options: %{restart: "permanent"}}
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
