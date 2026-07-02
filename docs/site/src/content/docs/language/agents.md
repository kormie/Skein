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
| `state { ... }` | Declares the agent's state field schema (see [State](#state)) |
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

- **Invalid transition (E0030):** Transitioning to a phase that is not in the current phase's declared target list is a compile error. With the enum above, `transition(Phase.Failed)` inside `on phase(Phase.Analyze)` is an E0030 error because `Failed` is not in `Analyze`'s target list (`Analyze -> [Refund, Done]`).
- **Unreachable phase (E0031):** A phase that no other phase can transition to (and isn't the start target) generates a warning.
- **Missing phase handler (E0032):** Every phase variant must have a corresponding `on phase(Phase.X)` handler.

## Lifecycle

### Starting an Agent

The `on start` handler runs once when the agent is created. It receives typed parameters and must transition to an initial phase (or stop). Start parameters are bindings local to the `on start` body — write anything later phases need to `memory.kv`:

```skein
agent OrderProcessor {
  capability memory.kv("orders")

  enum Phase {
    Validate -> [Process, Reject]
    Process -> [Done]
    Reject -> [Done]
    Done -> []
  }

  on start(order_id: String, amount: Int) -> {
    memory.put("order_id", order_id)
    memory.put("amount", amount)
    transition(Phase.Validate)
  }

  on phase(Phase.Validate) -> {
    let amount = memory.get("amount")!
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

The `state` block declares the agent's typed state field schema. In 1.0 it is a **declaration only**: start parameters are not merged into the runtime state map (`get_state/1` returns `%{}`), and `transition(Phase.X)` takes exactly one argument — the target phase — so transitions cannot carry state updates either.

The supported way to carry data across phases is `memory.kv`, the same pattern the canonical `examples/refund_agent.skein` uses — write in `on start`, read in phase handlers:

```skein
agent RefundBot {
  capability memory.kv("refunds")

  enum Phase {
    Analyze -> [Done]
    Done -> []
  }

  on start(ticket_id: Uuid, customer_id: String) -> {
    memory.put("ticket_id", ticket_id)
    memory.put("customer_id", customer_id)
    transition(Phase.Analyze)
  }

  on phase(Phase.Analyze) -> {
    let ticket_id = memory.get("ticket_id")!
    let customer_id = memory.get("customer_id")!
    transition(Phase.Done)
  }

  on phase(Phase.Done) -> {
    stop()
  }
}
```

## Capabilities

Agents declare capabilities just like modules. Common agent capabilities:

| Capability | Purpose |
|-----------|---------|
| `capability model("claude-opus-4-8")` | Use an LLM model |
| `capability memory.kv("sessions")` | Scoped key-value storage |
| `capability http.out("api.example.com")` | Make outbound HTTP calls |
| `capability store.table("tickets", Ticket)` | Database storage, typed by the `Ticket` record |
| `capability tool.use(Stripe.CreateRefund)` | Call a declared tool |

```skein
agent Classifier {
  capability model("anthropic", "claude-opus-4-8")
  capability memory.kv("classifications")

  enum Phase {
    Classify -> []
  }

  on start(text: String) -> {
    memory.put("text", text)
    transition(Phase.Classify)
  }

  on phase(Phase.Classify) -> {
    let text = memory.get("text")!
    let label = llm.chat("claude-opus-4-8", "Classify this text.", text)!
    memory.put("latest_label", label)
    stop()
  }
}
```

## LLM Integration

Agents can call LLM models for decision-making via the `llm.*` effects:

### `llm.chat` — Unstructured Text

```skein
on phase(Phase.Analyze) -> {
  let text = memory.get("text")!
  let analysis = llm.chat("claude-opus-4-8", "Analyze this input", text)!
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
  let description = memory.get("ticket_description")!
  let decision = llm.json[Decision](
    "claude-opus-4-8",
    "Decide if this warrants a refund",
    description
  )!
  -- decision is validated against the Decision type's JSON Schema
}
```

### `llm.stream` — Streaming Responses

```skein
on phase(Phase.Generate) -> {
  let data = memory.get("data")!
  let result = llm.stream("claude-opus-4-8", "Generate a report", data)
  -- chunks are delivered to the runtime callback; result is the assembled text
}
```

All LLM calls require a `capability model("model-name")` declaration and are automatically traced.

## Memory

Agents use `memory.kv` for scoped key-value storage that persists across phase transitions:

```skein
agent SessionTracker {
  capability memory.kv("sessions")

  enum Phase {
    Active -> []
  }

  on start(user_id: String) -> {
    memory.put("current_user", user_id)
    transition(Phase.Active)
  }

  on phase(Phase.Active) -> {
    let user = memory.get("current_user")!
    let keys = memory.list("user:")
    memory.delete("old_key")
    stop()
  }
}
```

Each namespace requires a `memory.kv` capability declaration. Memory is backed by a single ETS table (`:skein_memory`) keyed by `{namespace, key}`.

## Events

Use `emit` to record domain events. Events are append-only and queryable via `get_events/1` on the agent process:

```skein
on phase(Phase.Approved) -> {
  let ticket_id = memory.get("ticket_id")!
  let amount = memory.get("amount")!
  emit RefundIssued {
    ticket_id: ticket_id,
    amount: amount,
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
  capability memory.kv("payments")

  enum Phase {
    Refund -> [Done, Failed]
    Done -> []
    Failed -> []
  }

  on start(customer_id: String, amount: Int) -> {
    memory.put("customer_id", customer_id)
    memory.put("amount", amount)
    transition(Phase.Refund)
  }

  on phase(Phase.Refund) -> {
    let customer_id = memory.get("customer_id")!
    let amount = memory.get("amount")!
    let result = tool.call(Stripe.CreateRefund, {
      customer_id: customer_id,
      amount: amount
    })
    match result {
      Ok(refund) -> transition(Phase.Done)
      Err(e) -> transition(Phase.Failed)
    }
  }

  on phase(Phase.Done) -> {
    stop()
  }

  on phase(Phase.Failed) -> {
    stop()
  }
}
```

Tool calls require `capability tool.use(ToolName)` and are traced with timing and outcome.

## Helper Functions

Agents can declare `fn` functions, callable from the agent's own handlers and other helper functions (and, for a nested agent, the enclosing module's `fn`s are callable too):

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
module Refunds {
  type RefundDecision {
    action: String @one_of(["approve", "deny"])
    amount: Int @min(0)
  }

  agent RefundAgent {
    capability model("anthropic", "claude-opus-4-8")
    capability memory.kv("refund_sessions")
    capability tool.use(Stripe.CreateRefund)

    enum Phase {
      Analyze  -> [Refund, Done]
      Refund   -> [Done, Failed]
      Failed   -> [Analyze]
      Done     -> []
    }

    on start(ticket_id: Uuid, customer_id: String) -> {
      memory.put("ticket_id", ticket_id)
      memory.put("customer_id", customer_id)
      transition(Phase.Analyze)
    }

    on phase(Phase.Analyze) -> {
      let ticket_id = memory.get("ticket_id")!
      let decision = llm.json[RefundDecision](
        "claude-opus-4-8",
        "Decide if this ticket warrants a refund.",
        ticket_id
      )!
      memory.put("decision_action", decision.action)
      memory.put("decision_amount", decision.amount)
      match decision.action {
        "approve" -> transition(Phase.Refund)
        "deny"    -> transition(Phase.Done)
      }
    }

    on phase(Phase.Refund) -> {
      let ticket_id = memory.get("ticket_id")!
      let customer_id = memory.get("customer_id")!
      let amount = memory.get("decision_amount")!
      let result = tool.call(Stripe.CreateRefund, {
        customer_id: customer_id,
        amount: amount
      })
      match result {
        Ok(refund) -> {
          emit RefundIssued { ticket_id: ticket_id, refund_id: refund.id }
          transition(Phase.Done)
        }
        Err(e) -> {
          emit RefundFailed { ticket_id: ticket_id, error: e }
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
}
```

## Compilation

A top-level agent named `RefundAgent` compiles to `Elixir.Skein.Agent.RefundAgent`; nested inside `module Refunds` (as above) it compiles to `Elixir.Skein.Agent.Refunds.RefundAgent`. Either way the module carries these generated functions:

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
{:ok, pid} = Skein.Agent.Refunds.RefundAgent.start_link(%{
  ticket_id: "ticket-123",
  customer_id: "cust-456"
})

# Query state (while agent is alive)
Skein.Runtime.Agent.get_phase(pid)
#=> :analyze

# The runtime state map stays empty in 1.0 — agent data lives in memory.kv
Skein.Runtime.Agent.get_state(pid)
#=> %{}

# Emitted events are keyed by :event
Skein.Runtime.Agent.get_events(pid)
#=> [%{event: "RefundIssued", ticket_id: "ticket-123", refund_id: "ref_789"}]
```

## Supervision

Supervisor declarations can name agents as children. The declaration is validated at compile time and emitted as `__supervisors__/0` metadata, and under `skein run` the runtime boots a real OTP supervisor from it ([#325](https://github.com/kormie/Skein/issues/325)) — `Skein.Runtime.SupervisorHost` starts each child agent with its declared restart policy (`permanent`, `transient`, `temporary`), applies the `strategy:` and `max_restarts:` intensity, and appends a `:child_started` event to the EventStore on every start and restart:

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

Agents are tested using Skein's built-in test constructs. Test blocks are module-level declarations, so they live inside a module:

```skein
module RefundAgentTests {
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
}
```

For deterministic testing, the LLM client uses a pluggable backend system. In tests, `Skein.Runtime.Llm.TestBackend` returns canned responses, ensuring agent phase transitions are deterministic and reproducible.

See [Testing](/Skein/language/testing/) for the full testing guide.
