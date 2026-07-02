---
title: Agents
description: How Skein agents compile to gen_statem state machines and run on the BEAM.
---

## Overview

Agents are the core construct in Skein for building stateful, phase-driven services. Each agent is a state machine with:

- A **Phase** enum defining valid states and transitions
- **State** fields for persistent data across phases
- An **`on start`** handler that initializes the agent
- **`on phase`** handlers that execute when entering each phase
- **Capabilities** for memory, LLM, HTTP, and other effects

At runtime, agents compile to `:gen_statem` processes managed by `Skein.Runtime.Agent`.

## Skein Source

```skein
agent RefundBot {
  capability model("anthropic", "claude-opus-4-8")
  capability memory.kv("sessions")

  state {
    request_id: String
    amount: Int
  }

  enum Phase {
    Review -> [Approved, Denied]
    Approved -> [Done]
    Denied -> [Done]
    Done -> []
  }

  on start(request_id: String, amount: Int) -> {
    memory.put("request_id", request_id)
    memory.put("amount", amount)
    transition(Phase.Review)
  }

  on phase(Phase.Review) -> {
    let amount = memory.get("amount")!
    let decision = llm.chat("claude-opus-4-8", "Evaluate refund. Reply approve or deny.", amount)
    match decision {
      Ok("approve") -> transition(Phase.Approved)
      _ -> transition(Phase.Denied)
    }
  }

  on phase(Phase.Approved) -> {
    let amount = memory.get("amount")!
    emit RefundApproved { amount: amount }
    transition(Phase.Done)
  }

  on phase(Phase.Denied) -> {
    let amount = memory.get("amount")!
    emit RefundDenied { amount: amount }
    transition(Phase.Done)
  }

  on phase(Phase.Done) -> {
    stop()
  }
}
```

## Compilation

The compiler processes agents through all four analyzer passes:

1. **Name resolution** -- registers the agent, its Phase enum variants, state fields, and handlers
2. **Type checking** -- validates state field types and handler expressions
3. **Capability checking** -- verifies `memory.kv`, `model`, `http.out`, `store.table` capabilities against effect calls in handlers
4. **Transition checking** -- validates that every `transition(Phase.X)` call targets a phase reachable from the current handler's phase via the `->` declarations

### Generated Module

An agent named `RefundBot` compiles to `Elixir.Skein.Agent.RefundBot` with these functions:

| Function | Purpose |
|----------|---------|
| `start_link/1` | Start the agent with initial params |
| `__phases__/0` | Return phase metadata (variants and valid transitions) |
| `__capabilities__/0` | Return declared capabilities as a list of maps |
| `__start_handler__/2` | Execute the `on start(...)` handler |
| `__phase_handler__/3` | Execute phase-specific handlers, dispatched by phase atom |

### Nesting Inside Modules

Agents can be declared inside a module (the spec section 8.4 shape):

```skein
module RefundService {
  capability model("anthropic", "claude-opus-4-8")

  type RefundDecision { action: String }

  agent RefundAgent {
    capability memory.kv("refund_sessions")
    -- ...
  }
}
```

A nested agent compiles to its own BEAM module namespaced under the parent
(`Skein.Agent.RefundService.RefundAgent`) alongside the module's
(`Skein.User.RefundService`). It sees the module's `type` declarations (so
`llm.json[RefundDecision]` works in handlers) and the module's capabilities
apply to it in addition to its own. Top-level agents (one per file) work
unchanged — `examples/market_research/` ships both shapes.

Agents never declare `type` blocks of their own — nesting is *the* way to use
named types from an agent. The derived JSON Schema flows into `llm.json[T]`
requests made from nested agent handlers.

### Transition Validation (E0030)

The analyzer checks transition validity at compile time. Given the Phase enum:

```skein
enum Phase {
  Review -> [Approved, Denied]
  Approved -> [Done]
  Denied -> [Done]
  Done -> []
}
```

A `transition(Phase.Done)` call inside `on phase(Phase.Review)` would be a compile error -- `Review` can only transition to `Approved` or `Denied`.

## Runtime

### Process Lifecycle

`Skein.Runtime.Agent` manages the `:gen_statem` lifecycle:

```
start_link(args)
    │
    ▼
init: call __start_handler__(args, state)
    │
    ├── {:transition, phase, state, events}
    │       → move to phase, queue :execute_phase
    │
    ├── {:stop, state, events}
    │       → terminate normally
    │
    └── {:keep, state, events}
            → stay in :__idle__ state
```

When `:execute_phase` fires:

```
handle_event(:internal, :execute_phase, phase, data)
    │
    ▼
call __phase_handler__(phase, state, events)
    │
    ├── {:transition, next_phase, state, events}
    │       → move to next_phase, queue :execute_phase again
    │
    ├── {:stop, state, events}
    │       → terminate normally
    │
    └── {:keep, state, events}
            → stay in current phase, wait for external events
```

### Querying Agent State

```elixir
{:ok, pid} = Skein.Agent.RefundBot.start_link(%{request_id: "abc", amount: 100})

Skein.Runtime.Agent.get_phase(pid)
#=> :done

Skein.Runtime.Agent.get_state(pid)
#=> %{}  (RefundBot persists its data via memory.kv, not state fields)

Skein.Runtime.Agent.get_events(pid)
#=> [%{event: "RefundApproved", amount: 100}]
```

`start_link/1` takes a map keyed by the `on start(...)` parameter names.

### Handler Return Values

Agent handlers communicate via tagged tuples:

| Return | Meaning |
|--------|---------|
| `{:transition, phase, state, events}` | Move to `phase`, merge `state`, append `events`, then execute phase handler |
| `{:suspend, reason, state, events}` | Pause the agent with a reason string; agent enters `:suspended` state |
| `{:stop, state, events}` | Terminate the agent normally |
| `{:keep, state, events}` | Stay in current phase, merge state and events |

The code generator maps Skein constructs to these tuples:
- `transition(Phase.Review)` → `{:transition, :review, state_updates, new_events}`
- `suspend(reason)` → `{:suspend, reason_string, state_updates, new_events}`
- `stop()` → `{:stop, state_updates, new_events}`
- `emit EventName { field: value }` → appends `%{event: "EventName", field: value}` to the events list **and** flushes to the EventStore as a `:user_event` (tagged with agent name, instance id, and phase) after the handler completes — events emitted before a crash survive, and `EventStore.query(kind: :user_event)` sees them

### Suspending and Resuming

When a handler returns `{:suspend, reason, state, events}`, the agent enters the `:suspended` state. The agent process stays alive but does not execute any phase handlers. See [Language > Agents: Suspending](/Skein/language/agents/#suspending-and-resuming) for the Skein syntax.

**Runtime API for suspended agents:**

```elixir
# Check if an agent is suspended
Skein.Runtime.Agent.is_suspended?(pid)
#=> true

# Get the suspension reason
Skein.Runtime.Agent.get_suspend_reason(pid)
#=> "Requires human review"

# Resume the agent to a specific phase
Skein.Runtime.Agent.resume(pid, :done)
#=> :ok
```

Resume transitions the agent from `:suspended` to the specified phase and executes the phase handler. If the agent is not suspended, `resume/2` returns `{:error, :not_suspended}`.

## Memory Integration

Agents use `memory.kv` for scoped key-value storage that persists across phase transitions:

```skein
agent SessionTracker {
  capability memory.kv("sessions")

  enum Phase {
    Active -> []
  }

  on start(session_id: String, data: String) -> {
    memory.put(session_id, data)
    memory.put("current", session_id)
    transition(Phase.Active)
  }

  on phase(Phase.Active) -> {
    let session_id = memory.get("current")!
    let data = memory.get(session_id)!
    trace.annotate("session_data", data)
    stop()
  }
}
```

The namespace comes from the scoped `capability memory.kv(namespace)` declaration (at most one per agent) -- call sites pass only the key, and the compiler threads the namespace into every generated runtime call. Memory is backed by a single shared ETS table (`:skein_memory`) keyed by `{namespace, key}` -- namespaces are never separate tables. Inside agents, keys are additionally prefixed with the agent name and instance id, so concurrent instances never collide.

## LLM Integration

Agents can call LLM models for decision-making. Schema-constrained `llm.json[T]` needs a named type, and agents never declare `type` blocks of their own -- so an agent that wants structured output is nested inside the module that declares the type (see [Nesting Inside Modules](#nesting-inside-modules) above):

```skein
module ClassifyService {
  capability model("anthropic", "claude-opus-4-8")

  type Decision {
    action: String
  }

  agent Classifier {
    capability memory.kv("classifier")

    enum Phase {
      Classify -> []
    }

    on start(text: String) -> {
      memory.put("text", text)
      transition(Phase.Classify)
    }

    on phase(Phase.Classify) -> {
      let text = memory.get("text")!

      -- Unstructured text response
      let analysis = llm.chat("claude-opus-4-8", "Classify this input", text)
      trace.annotate("analysis", analysis)

      -- Schema-constrained JSON response (uses the module's Decision type)
      let decision = llm.json[Decision](
        model: "claude-opus-4-8",
        system: "Decide the action. Return JSON.",
        input: text
      )
      memory.put("decision", decision)

      stop()
    }
  }
}
```

The LLM client uses a pluggable backend system. In tests, `Skein.Runtime.Llm.TestBackend` returns deterministic responses. In production, calls are served by the shipped `AnthropicBackend`, `OpenAiCompatibleBackend`, or `BedrockBackend` (selected via the `[llm]` profile in skein.toml); custom backends implement the `Skein.Runtime.Llm.Backend` behaviour.
