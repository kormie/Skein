---
title: Agents
description: Declaring and building stateful AI agents in Skein with phases, transitions, LLM integration, memory, tools, and events.
---

## Overview

Agents are Skein's core construct for building **stateful, phase-driven AI services**. An agent is a state machine where each phase can call LLMs, invoke tools, read/write memory, emit events, and transition to the next phase. At runtime, agents compile to OTP `gen_statem` processes — battle-tested Erlang state machines with built-in supervision and fault tolerance.

Agents are designed for workflows like:
- Evaluating a refund request by analyzing a ticket, deciding eligibility, and issuing the refund
- Triaging an incident by classifying severity, routing to the right team, and escalating if needed
- Processing an order through validation, payment, fulfillment, and notification stages

## Agent Syntax

```skein
agent <Name> {
  capability <effect>

  state {
    <field>: <Type>
  }

  enum Phase {
    <Variant> -> [<Target>, ...]
    ...
  }

  on start(<params>) -> {
    -- initialization logic
    transition(Phase.<Variant>)
  }

  on phase(Phase.<Variant>) -> {
    -- phase logic
    transition(Phase.<NextVariant>)
  }

  fn <name>(<params>) -> <ReturnType> {
    -- helper functions
  }
}
```

### Required Elements

Every agent must declare:

| Element | Purpose |
|---------|---------|
| `enum Phase { ... }` | Defines valid states and transitions between them |
| `on start(...)` | Initialization handler — runs when the agent is created |
| `on phase(Phase.X)` | Phase handler — runs when the agent enters phase X |

### Optional Elements

| Element | Purpose |
|---------|---------|
| `capability` | Declares effects the agent may use (LLM, memory, HTTP, etc.) |
| `state { ... }` | Typed fields that persist across phase transitions |
| `fn` | Helper functions callable from within or outside the agent |

## Phase Enum and Transitions

The `Phase` enum declares which states the agent can be in and which transitions are valid. The `->` syntax specifies allowed target phases.

```skein
enum Phase {
  Analyze  -> [Refund, Done]    -- Analyze can go to Refund or Done
  Refund   -> [Done, Failed]    -- Refund can go to Done or Failed
  Failed   -> [Analyze]         -- Failed can retry by going back to Analyze
  Done     -> []                -- Done is terminal (no transitions out)
}
```

### Compile-Time Validation

The Skein analyzer validates transitions at compile time:

- **Invalid transition (E0030):** `transition(Phase.Done)` inside `on phase(Phase.Analyze)` is a compile error because `Analyze -> [Refund, Done]` does not include a direct path that bypasses the declared targets. Wait — `Done` *is* in the list, so that would be valid. A call to `transition(Phase.Failed)` from `on phase(Phase.Analyze)` *would* be an error since `Failed` is not in `Analyze`'s target list.
- **Unreachable phase (E0031):** A phase that no other phase can transition to (and isn't the start target) generates a warning.
- **Missing phase handler (E0032):** Every phase variant must have a corresponding `on phase(Phase.X)` handler.

## Lifecycle

### Starting an Agent

The `on start` handler runs once when the agent is created. It receives typed parameters and must transition to an initial phase (or stop).

```skein
agent OrderProcessor {
  enum Phase {
    Validate -> [Process, Reject]
    Process -> [Done]
    Reject -> [Done]
    Done -> []
  }

  on start(order_id: String, amount: Int) -> {
    transition(Phase.Validate)
  }

  on phase(Phase.Validate) -> {
    match amount > 0 {
      true -> transition(Phase.Process)
      false -> transition(Phase.Reject)
    }
  }

  on phase(Phase.Process) -> {
    transition(Phase.Done)
  }

  on phase(Phase.Reject) -> {
    transition(Phase.Done)
  }

  on phase(Phase.Done) -> {
    stop()
  }
}
```

### Phase Execution

When a phase handler runs via `transition(Phase.X)`, the gen_statem moves to state `:x` and queues an internal `:execute_phase` event. The handler for that phase then executes. This means phase handlers run **sequentially** — one phase completes before the next begins.

### Stopping

Call `stop()` to terminate the agent normally. This is typically done in terminal phases:

```skein
on phase(Phase.Done) -> {
  stop()
}
```

### Suspending and Resuming

Call `suspend(reason)` to pause an agent for human-in-the-loop review or external input. The agent enters a `:suspended` state and waits until resumed externally:

```skein
on phase(Phase.Failed) -> {
  suspend("Requires human review")
}
```

A suspended agent stays alive but does not execute any phase handlers until resumed from outside. This is the primary mechanism for pausing agent workflows that need human intervention.

Resume from Elixir:

```elixir
Skein.Runtime.Agent.resume(pid, :analyze)
```

See [Runtime > Agents: Suspending and Resuming](/Skein/runtime/agents/#suspending-and-resuming) for the full runtime API (`is_suspended?/1`, `get_suspend_reason/1`, `resume/2`).

### Control Flow Summary

| Construct | Meaning |
|-----------|---------|
| `transition(Phase.X)` | Move to phase X and execute its handler |
| `stop()` | Terminate the agent process normally |
| `suspend(reason)` | Pause the agent for external input |
| `emit EventName { field: value }` | Record a domain event |

## State

The `state` block declares typed fields that persist across phase transitions:

```skein
agent RefundBot {
  state {
    ticket_id: Uuid
    customer_id: String
    amount: Int
  }

  on start(ticket_id: Uuid, customer_id: String) -> {
    transition(Phase.Analyze)
  }

  on phase(Phase.Analyze) -> {
    -- state fields are available via the state map
    -- state.ticket_id, state.customer_id, state.amount
    transition(Phase.Done)
  }
}
```

State is a map that accumulates updates across transitions. Each `transition()` call can include state updates which are merged into the existing state.

## Capabilities

Agents declare capabilities just like modules. Common agent capabilities:

| Capability | Purpose |
|-----------|---------|
| `capability model("claude-opus-4-8")` | Use an LLM model |
| `capability memory.kv("sessions")` | Scoped key-value storage |
| `capability http.out("api.example.com")` | Make outbound HTTP calls |
| `capability store.table("tickets")` | Database storage |
| `capability tool.use(Stripe.CreateRefund)` | Call a declared tool |

```skein
agent Classifier {
  capability model("claude-opus-4-8")
  capability memory.kv("classifications")

  -- LLM and memory calls are now allowed in phase handlers
}
```

## LLM Integration

Agents can call LLM models for decision-making via the `llm.*` effects:

### `llm.chat` — Unstructured Text

```skein
on phase(Phase.Analyze) -> {
  let analysis = llm.chat("claude-opus-4-8", "Analyze this input", state.input)
  -- analysis is a String
}
```

### `llm.json` — Schema-Constrained JSON

```skein
type Decision {
  action: String @one_of(["approve", "deny"])
  amount: Int @min(0)
  reason: String
}

on phase(Phase.Decide) -> {
  let decision = llm.json[Decision](
    "claude-opus-4-8",
    "Decide if this warrants a refund",
    state.ticket_description
  )
  -- decision is validated against the Decision type's JSON Schema
}
```

### `llm.stream` — Streaming Responses

```skein
on phase(Phase.Generate) -> {
  let result = llm.stream("claude-opus-4-8", "Generate a report", state.data)
  -- chunks are delivered to the runtime callback; result is the assembled text
}
```

All LLM calls require a `capability model("model-name")` declaration and are automatically traced.

## Memory

Agents use `memory.kv` for scoped key-value storage that persists across phase transitions:

```skein
agent SessionTracker {
  capability memory.kv("sessions")

  on phase(Phase.Active) -> {
    memory.put("sessions", "current_user", state.user_id)
    let user = memory.get("sessions", "current_user")
    let keys = memory.list("sessions", "user:")
    memory.delete("sessions", "old_key")
  }
}
```

Each namespace requires a `memory.kv` capability declaration. Memory is backed by ETS with per-namespace tables.

## Events

Use `emit` to record domain events. Events are append-only and queryable via `get_events/1` on the agent process:

```skein
on phase(Phase.Approved) -> {
  emit RefundIssued {
    ticket_id: state.ticket_id,
    amount: state.amount,
    refund_id: "ref_123"
  }
  transition(Phase.Done)
}
```

Events accumulate in the agent's event log across all phase transitions.

## Tool Calling

Agents can invoke declared tools for external integrations:

```skein
agent PaymentAgent {
  capability tool.use(Stripe.CreateRefund)

  on phase(Phase.Refund) -> {
    let result = tool.call(Stripe.CreateRefund, {
      customer_id: state.customer_id,
      amount: state.amount
    })
    match result {
      Ok(refund) -> transition(Phase.Done)
      Err(e) -> transition(Phase.Failed)
    }
  }
}
```

Tool calls require `capability tool.use(ToolName)` and are traced with timing and outcome.

## Helper Functions

Agents can declare `fn` functions that are callable both within the agent and from external code:

```skein
agent UtilAgent {
  enum Phase {
    Init -> []
  }

  fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }

  on start() -> {
    transition(Phase.Init)
  }

  on phase(Phase.Init) -> {
    stop()
  }
}
```

```elixir
# Called from Elixir
Skein.Agent.UtilAgent.add(3, 4)
#=> 7
```

## Complete Example: Refund Agent

```skein
agent RefundAgent {
  capability model("claude-opus-4-8")
  capability memory.kv("refund_sessions")
  capability tool.use(Stripe.CreateRefund)

  state {
    ticket_id: Uuid
    customer_id: String
  }

  enum Phase {
    Analyze  -> [Refund, Done]
    Refund   -> [Done, Failed]
    Failed   -> [Analyze]
    Done     -> []
  }

  on start(ticket_id: Uuid, customer_id: String) -> {
    transition(Phase.Analyze)
  }

  on phase(Phase.Analyze) -> {
    let decision = llm.json[RefundDecision](
      "claude-opus-4-8",
      "Decide if this ticket warrants a refund.",
      state.ticket_id
    )
    memory.put("refund_sessions", "decision", decision)
    match decision.action {
      "approve" -> transition(Phase.Refund)
      "deny"    -> transition(Phase.Done)
    }
  }

  on phase(Phase.Refund) -> {
    let d = memory.get!("refund_sessions", "decision")
    let result = tool.call(Stripe.CreateRefund, {
      customer_id: state.customer_id,
      amount: d.amount
    })
    match result {
      Ok(refund) -> {
        emit RefundIssued { ticket_id: state.ticket_id, refund_id: refund.id }
        transition(Phase.Done)
      }
      Err(e) -> {
        emit RefundFailed { ticket_id: state.ticket_id, error: e }
        transition(Phase.Failed)
      }
    }
  }

  on phase(Phase.Failed) -> {
    transition(Phase.Analyze)
  }

  on phase(Phase.Done) -> {
    stop()
  }
}
```

## Compilation

An agent named `RefundAgent` compiles to `Elixir.Skein.Agent.RefundAgent` with these generated functions:

| Function | Purpose |
|----------|---------|
| `start_link/1` | Start the agent with initial params |
| `__phases__/0` | Return phase metadata (variants and valid transitions) |
| `__capabilities__/0` | Return declared capabilities |
| `__start_handler__/2` | Execute the `on start(...)` handler |
| `__phase_handler__/3` | Execute phase-specific handlers, dispatched by phase atom |

### Using from Elixir

```elixir
# Start the agent
{:ok, pid} = Skein.Agent.RefundAgent.start_link(%{
  ticket_id: "ticket-123",
  customer_id: "cust-456"
})

# Query state (while agent is alive)
Skein.Runtime.Agent.get_phase(pid)
#=> :analyze

Skein.Runtime.Agent.get_state(pid)
#=> %{ticket_id: "ticket-123", customer_id: "cust-456"}

Skein.Runtime.Agent.get_events(pid)
#=> [%{type: "RefundIssued", ticket_id: "ticket-123", refund_id: "ref_789"}]
```

## Supervision

Agents can be managed by Skein supervisors for automatic restart on failure:

```skein
supervisor RefundPool {
  child RefundAgent {
    restart: permanent
  }
  strategy: one_for_one
  max_restarts: 5 per 60s
}
```

See [Supervisors](/Skein/language/supervisors/) for details.

## Testing Agents

Agents are tested using Skein's built-in test constructs:

```skein
test "refund agent approves valid refund" {
  -- Unit tests can compile and start agents
  assert true == true
}

scenario "refund flow" {
  given {
    ticket_id: "t-123"
    customer_id: "c-456"
  }
  expect {
    assert ticket_id == "t-123"
  }
}
```

For deterministic testing, the LLM client uses a pluggable backend system. In tests, `Skein.Runtime.Llm.TestBackend` returns canned responses, ensuring agent phase transitions are deterministic and reproducible.

See [Testing](/Skein/language/testing/) for the full testing guide.
