# Skein Language Design — From First Principles

**A BEAM language designed for humans to build agent services, and for agents to write code in.**

*Draft — February 2026*

---

## 0. The Core Insight

Most programming languages are designed for humans to write and machines to execute. Skein is designed for a third audience: **LLM agents that generate, modify, and reason about code as a primary workflow**. This isn't a secondary concern bolted onto a human-friendly language — it's a co-equal design constraint that shapes every decision from syntax to semantics to tooling.

The insight is this: the properties that make a language easy for an LLM to generate correctly — regularity, small surface area, explicit structure, unambiguous parsing, typed contracts — also make it *better for humans* building agent systems where reliability matters more than expressiveness.

Skein sits at the intersection of three ideas:

1. **The BEAM/OTP runtime** gives us battle-tested concurrency, fault tolerance, and distribution primitives — exactly what long-running agent processes need.
2. **Darklang's integrated platform model** gives us trace-driven development, zero-config deployment, and the "service as the unit of work" philosophy.
3. **Agent-writability as a first-class design constraint** gives us a language whose entire specification fits in context, whose syntax is maximally regular, and whose type system doubles as a contract language for LLM tool calling.

---

## 1. Design Principles (Ranked)

These are in priority order. When principles conflict, higher-ranked ones win.

### P1: One Obvious Way

For any given task, there should be exactly one idiomatic way to express it. No synonyms, no sugar, no "equivalent alternatives." This is the single most important property for agent-writability — LLMs generate more reliable code when there's less ambiguity about which construct to use.

This means: no operator overloading, no implicit conversions, no method aliases, no do-notation vs. block syntax choices. The language is opinionated by design.

### P2: The Spec Fits in Context

The complete language specification — grammar, type rules, standard library signatures, and canonical examples — must fit within 128K tokens. This is a hard constraint, not an aspiration. An LLM should be able to hold the *entire language* in its context window while generating code.

This means: a small number of constructs, a curated standard library, and aggressive resistance to feature creep. Every addition must justify its token budget.

### P3: Types Are Contracts

The type system serves triple duty: it catches bugs at compile time, it generates schemas for LLM tool calling and HTTP APIs, and it provides structured specifications that constrain agent-generated code. Types aren't just for correctness — they're the interface language between human intent and machine execution.

### P4: Effects Are Visible

Every side effect — network calls, storage, model invocations, message passing — is declared, traced, and replayable. There is no way to "sneak" an effect past the capability system. This isn't just for security; it's for debuggability, auditability, and deterministic replay.

### P5: Crash Gracefully

OTP's "let it crash" philosophy is the right default for agent workloads where failures are expected and frequent. The language should make supervision and recovery easy, not defensive programming.

### P6: Humans Read, Agents Write, Both Succeed

Syntax should be readable by humans and reliably generable by LLMs. When these conflict (rarely), favor the choice that reduces LLM generation errors — humans can learn conventions, but LLMs are brittle to ambiguity.

---

## 2. Why the BEAM (Briefly)

This section exists because every language design must justify its runtime choice, and the BEAM's properties are unusually well-matched to agent workloads.

**Agents are processes.** An agent session is a long-running computation that maintains state, receives messages, calls external services, and may run for minutes or hours. BEAM processes are cheap (millions per node), isolated (one crash doesn't poison the rest), and supervised (automatic restart with configurable strategies). The mapping is direct.

**Tool calls are messages.** When an agent calls a tool, it sends a request and waits for a response — possibly with a timeout, possibly with a fallback. BEAM's message passing and selective receive are a natural fit.

**Deployment is continuous.** Agent services need to stay running while code changes. OTP hot code upgrades let you push new handler logic, new agent behavior, or new tool definitions without dropping in-flight sessions.

**Distribution is built in.** Multi-region, multi-tenant agent services need clustering. BEAM nodes can discover each other, pass messages across the network, and rebalance work — without bolting on Kubernetes service mesh complexity.

---

## 3. Syntax Design

### 3.1 Guiding Constraint: Regularity Over Cleverness

Skein's syntax is designed around a single meta-rule: **every construct follows the same structural pattern**. There are no special forms, no context-dependent parsing, no "this keyword means different things in different positions."

The universal pattern is:

```
<keyword> <name> <signature>? <block>
```

Everything in the language — handlers, agents, tools, types, tests — follows this shape. An LLM that learns the pattern once can generate any construct.

### 3.2 Blocks and Expressions

Blocks use braces. Always. No significant whitespace, no optional braces, no "single-expression shorthand."

```
-- This is the only way to write a block.
{
  let x = compute(y)
  x + 1
}
```

The last expression in a block is its return value. There is no `return` keyword. (One way to do things.)

Comments use `--` (double dash). No block comments. (One way to do things.)

### 3.3 Bindings

All bindings use `let`. Bindings are immutable. There is no `mut`, `var`, or reassignment.

```
let name = "Skein"
let count = items |> List.length()
```

Shadowing is allowed within a block scope (necessary for rebinding after transformations), but the original binding is gone — no confusion about which version is "current."

### 3.4 Functions

Functions use `fn`. Always named. No anonymous lambdas — use named local functions or pass function references. (This is a deliberate agent-writability choice: named functions are easier for LLMs to reason about and generate correctly than anonymous closures.)

```
fn calculate_refund(order: Order, reason: RefundReason) -> Result[Money, RefundError] {
  let eligible = check_eligibility(order, reason)
  match eligible {
    Ok(amount) -> Ok(Money.new(amount, order.currency))
    Err(e) -> Err(RefundError.Ineligible(e.reason))
  }
}
```

Function references use `&function_name` syntax for passing to higher-order functions:

```
let results = orders |> List.map(&calculate_total)
```

### 3.5 Pattern Matching

`match` is the only conditional construct. No `if/else`, no ternary, no `cond`, no `case`. (One way to do things.)

```
match status {
  Status.Active -> handle_active(user)
  Status.Suspended(reason) -> handle_suspended(user, reason)
  Status.Deleted -> Err(UserError.Gone)
}
```

For boolean conditions, use `match` with `true/false` or guard patterns:

```
match amount > threshold {
  true  -> escalate(ticket)
  false -> auto_approve(ticket)
}
```

This looks slightly verbose compared to `if/else`, but it eliminates a construct and LLMs never confuse the syntax.

### 3.6 Pipe Operator

The pipe `|>` is the primary composition mechanism. It threads the result of the left side as the first argument of the right side.

```
let summary =
  incident
  |> gather_context()
  |> enrich_with_deploys()
  |> llm.json[IncidentSummary](model: "claude-haiku-4-5", system: TRIAGE_PROMPT)
  |> unwrap_or_escalate()
```

No other composition mechanisms (no monadic do-notation, no async/await, no special chaining syntax). Pipes compose synchronous and effectful code uniformly because effects are explicit and handled by the runtime.

### 3.7 String Interpolation

One way to build strings:

```
let key = "decision:${ticket_id}"
let message = "Refund of ${amount} issued for ticket ${ticket_id}"
```

No format strings, no concatenation operator for strings, no template literals. `${}` always, with the expression inside evaluated and converted via its `Display` trait.

### 3.8 Collections

Three collection types, no more:

```
let list = [1, 2, 3]                               -- List[Int]
let map = { "name": "Alice", "role": "admin" }      -- Map[String, String]
let set = Set.from([1, 2, 3])                        -- Set[Int] (constructed, not literal)
```

Tuples exist for multi-return and destructuring but are not a general-purpose collection:

```
let (status, body) = http.get(url)
```

### 3.9 Complete Syntax Summary

This is the entire surface area. Every valid Skein program is composed of these constructs and nothing else:

| Construct | Pattern | Example |
|-----------|---------|---------|
| Module | `module Name { ... }` | `module Billing { ... }` |
| Function | `fn name(args) -> Type { ... }` | `fn refund(id: Uuid) -> Result[Refund, Err] { ... }` |
| Type | `type Name { ... }` | `type User { id: Uuid, email: Email }` |
| Enum | `enum Name { Variant, ... }` | `enum Phase { Gather, Analyze, Act, Done }` |
| Handler | `handler <source> <route> (arg) -> { ... }` | `handler http GET "/users/:id" (req) -> { ... }` |
| Agent | `agent Name { ... }` | `agent TriageAgent { ... }` |
| Tool | `tool Name(args) -> Type { ... }` | `tool Stripe.Refund(args) -> Result { ... }` |
| Capability | `capability <kind>(<params>)` | `capability http.out("api.stripe.com")` |
| Supervisor | `supervisor Name { ... }` | `supervisor Main { ... }` |
| Test | `test "description" { ... }` | `test "refund eligible order" { ... }` |
| Binding | `let name = expr` | `let user = User.get!(id)` |
| Match | `match expr { pattern -> expr, ... }` | `match phase { Phase.Act -> act() }` |
| Pipe | `expr \|> fn(args)` | `data \|> transform() \|> validate()` |

That's it. Twelve constructs. The entire grammar fits on one page.

---

## 4. Type System

### 4.1 Design Goal: Types as a Shared Language

Skein's types serve three audiences simultaneously:

1. **The compiler** uses them for static checking and inference.
2. **The runtime** uses them to generate JSON schemas, validate LLM outputs, and enforce API contracts.
3. **LLM agents** use them as structured specifications — a type definition is both documentation and constraint.

This triple duty means the type system must be simple enough to fit in context, expressive enough to model real domain contracts, and derivable enough to auto-generate schemas without annotation clutter.

### 4.2 Core Types

```
-- Primitives
Int, Float, String, Bool, Uuid, Instant, Duration, Email, Url

-- Wrappers
Option[T]          -- presence/absence (no nulls anywhere)
Result[T, E]       -- fallible operations
List[T]            -- ordered collection
Map[K, V]          -- key-value collection
Set[T]             -- unique collection

-- Records (structural)
type User {
  id: Uuid
  email: Email
  name: String
  created_at: Instant
}

-- Enums (algebraic)
enum PaymentStatus {
  Pending
  Charged(amount: Money, at: Instant)
  Refunded(amount: Money, reason: String)
  Failed(error: PaymentError)
}
```

### 4.3 Schema Derivation

Every named type automatically derives:

- **JSON encoder/decoder** (used for HTTP payloads, storage, and inter-process messages)
- **Tool schema** (used for LLM function calling manifests)
- **Migration diff** (used when a stored type's shape changes)
- **Display** (used for logging and string interpolation)

No annotations needed for the common case. The derivation is structural and deterministic — given a type definition, there is exactly one schema. Agents generating code never need to also generate serialization logic.

```
type RefundRequest {
  customer_id: String
  ticket_id: Uuid
  amount: Int
  reason: Option[String]
}

-- The above automatically produces a JSON schema equivalent to:
-- {
--   "type": "object",
--   "required": ["customer_id", "ticket_id", "amount"],
--   "properties": {
--     "customer_id": { "type": "string" },
--     "ticket_id": { "type": "string", "format": "uuid" },
--     "amount": { "type": "integer" },
--     "reason": { "type": "string" }
--   }
-- }
```

### 4.4 Constrained Types

Types can carry constraints that are checked at boundaries (deserialization, LLM output parsing, user input):

```
type Money {
  amount: Int @min(0)
  currency: String @one_of(["USD", "CAD", "EUR"])
}

type Pagination {
  page: Int @min(1)
  per_page: Int @min(1) @max(100) @default(25)
}
```

Constraints flow through to generated JSON schemas and tool definitions. An LLM calling a tool with a `Money` argument gets the constraints in its function-calling spec automatically.

### 4.5 Result Handling Convention

Fallible operations return `Result[T, E]`. The convention for propagation:

```
-- The ! suffix unwraps a Result, crashing the process on Err.
-- This is the "let it crash" path — use inside supervised processes.
let user = User.get!(id)

-- Explicit match for controlled error handling at boundaries.
let user = match User.get(id) {
  Ok(u) -> u
  Err(NotFound) -> respond.json(404, { "error": "not found" })
  Err(e) -> respond.json(500, { "error": e.message })
}

-- The ? suffix propagates the Err, returning early from the current function.
-- The enclosing function must return a compatible Result type.
fn process_order(id: Uuid) -> Result[Receipt, OrderError] {
  let order = Order.get(id)?
  let payment = charge(order)?
  Ok(Receipt.new(order, payment))
}
```

Three mechanisms: `!` (crash), `?` (propagate), `match` (handle). Always one of these. No exceptions, no try/catch, no implicit error swallowing.

---

## 5. Capabilities and Effects

### 5.1 The Core Idea

Every side effect in Skein requires a declared capability. Capabilities are declared at the module or handler level and are visible in code review, enforced at compile time, and auditable at runtime.

But capabilities in Skein serve a dual purpose that goes beyond traditional effect systems: **they are also a specification language for constraining agent-generated code.**

Consider this scenario: a human writes a capability block that defines what a coding agent is allowed to generate:

```
-- Human writes this "constitution" for the billing service
capability http.out("api.stripe.com", methods: [POST], paths: ["/v1/refunds", "/v1/charges"])
capability store.table("transactions")
capability model.anthropic("claude-opus-4-8")
capability tool.use(Stripe.Refund, Stripe.Charge)
```

An LLM generating code for this service *physically cannot* compile code that calls an unauthorized endpoint, uses an unapproved model, or accesses a table it shouldn't touch. The capability system is both security and specification.

### 5.2 Capability Kinds

```
-- Network
capability http.out(host: String, methods: List[Method]?, paths: List[String]?)
capability http.in                                    -- accept inbound HTTP

-- Storage
capability store.table(name: String, ops: List[Op]?)  -- ops: [read, write, delete, migrate]
capability memory.kv(namespace: String)
capability event.log(stream: String)

-- Messaging
capability topic.publish(name: String)
capability topic.consume(name: String)
capability queue.publish(name: String)
capability queue.consume(name: String)

-- AI Models
capability model(provider: String, model: String, max_cost_per_call: Money?)

-- Tools
capability tool.use(names: List[Tool])

-- System
capability process.spawn(agent: String?, max: Int?)
capability timer(max_duration: Duration?)
```

### 5.3 Capability Composition

Capabilities are additive and scoped. A module declares its maximum capability set; individual functions within it can use any subset.

```
module BillingService {
  capability http.out("api.stripe.com")
  capability store.table("invoices")
  capability model("anthropic", "claude-opus-4-8")

  -- This function can use http.out and store.table but not model.
  fn sync_invoice(id: Uuid) -> Result[Invoice, SyncError] {
    let remote = http.get("https://api.stripe.com/v1/invoices/${id}")
    let invoice = Invoice.from_stripe(remote?)
    store.invoices.put(invoice)?
    Ok(invoice)
  }

  -- This function can use model.
  fn classify_dispute(invoice: Invoice) -> Result[DisputeClass, ClassifyError] {
    llm.json[DisputeClass](
      model: "claude-opus-4-8",
      system: CLASSIFY_PROMPT,
      input: invoice
    )
  }
}
```

### 5.4 Capability Checking

Capabilities are checked at two levels:

**Compile time:** The compiler verifies that every effect call is covered by a declared capability. Missing capabilities are compilation errors, not warnings.

**Runtime:** The platform enforces capabilities as a second layer. Even if a bug bypasses compile-time checks (e.g., via FFI), the runtime blocks unauthorized effects. This defense-in-depth is critical for agent-generated code where the compiler is the first reviewer.

---

## 6. Agents

### 6.1 Agent as State Machine

An agent in Skein is an explicitly defined state machine running as a supervised OTP process. The key design choice: **agent phases and transitions are declared, not implicit.** This makes the agent's behavior enumerable, testable, and — critically — easier for an LLM to generate correctly.

```
agent RefundAgent {
  capability model("anthropic", "claude-opus-4-8")
  capability memory.kv("refund_sessions")
  capability tool.use(Stripe.CreateRefund)

  -- Explicit state with typed fields
  state {
    ticket_id: Uuid
    customer_id: String
    phase: Phase
  }

  -- Explicit phase enumeration with allowed transitions
  enum Phase {
    Analyze  -> [Refund, Done]       -- from Analyze, can go to Refund or Done
    Refund   -> [Done, Failed]       -- from Refund, can go to Done or Failed
    Failed   -> [Analyze]            -- from Failed, can retry Analyze
    Done     -> []                   -- terminal
  }

  on start(ticket_id: Uuid, customer_id: String) -> {
    transition(Phase.Analyze)
  }

  on phase(Phase.Analyze) -> {
    let ticket = Tickets.get!(state.ticket_id)

    let decision = llm.json[RefundDecision](
      model: "claude-opus-4-8",
      system: REFUND_ANALYSIS_PROMPT,
      input: ticket
    )

    memory.put("decision", decision)

    match decision.action {
      Action.Approve -> transition(Phase.Refund)
      Action.Deny    -> transition(Phase.Done)
    }
  }

  on phase(Phase.Refund) -> {
    let decision = memory.get!("decision")

    let result = tool.call(Stripe.CreateRefund, {
      customer_id: state.customer_id,
      ticket_id: state.ticket_id,
      amount: decision.amount
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
    -- Wait for human intervention or retry after backoff
    suspend(reason: "Refund failed, awaiting review")
  }
}
```

### 6.2 Why Explicit Transitions

The `Phase` enum with declared transitions (`Analyze -> [Refund, Done]`) is a critical design choice for agent-writability:

- **Compile-time verification:** The compiler rejects any `transition()` call that isn't in the declared transition set. An LLM generating agent code can't create an invalid state transition.
- **Visualization:** The phase graph can be rendered automatically — useful for documentation, debugging, and approval workflows.
- **Test generation:** Given a phase graph, the platform can auto-generate tests covering all paths (and warn about untested transitions).
- **Replay correctness:** During replay, the platform can verify that the replayed agent follows the same phase transitions as the original.

### 6.3 Agent Memory

Agent memory is scoped automatically. No manual key construction, no risk of cross-contamination between agent instances.

```
-- Inside an agent, memory is implicitly scoped to the agent instance.
memory.put("decision", decision)           -- stored as "RefundAgent:<instance_id>:decision"
let d = memory.get!("decision")            -- reads from the same scoped namespace

-- Explicit cross-agent read (requires capability)
let other = memory.read("TriageAgent", other_instance_id, "summary")
```

### 6.4 Agent Lifecycle

| Event | Behavior |
|-------|----------|
| `start(args)` | Initialize state, begin first phase |
| `transition(phase)` | Move to a new phase, trigger `on phase(...)` handler |
| `suspend(reason)` | Pause agent, checkpoint state, emit suspension event |
| `resume(input)` | Resume from suspension (human-in-the-loop or timer) |
| `stop()` | Graceful shutdown, final checkpoint |
| Process crash | Supervisor restarts, agent resumes from last checkpoint |

### 6.5 Streaming

LLM responses often stream token-by-token. Skein handles this with `stream` blocks that compose with the trace system:

```
on phase(Phase.Summarize) -> {
  let ctx = memory.get!("context")

  -- stream collects tokens and produces the final result
  let summary = llm.stream[IncidentSummary](
    model: "claude-opus-4-8",
    system: SUMMARIZE_PROMPT,
    input: ctx,
    on_chunk: fn chunk -> {
      -- Optional: forward chunks to a client websocket, log progress, etc.
      emit StreamChunk { content: chunk.text }
    }
  )

  memory.put("summary", summary)
  transition(Phase.Act)
}
```

The `llm.stream` call is a single traced span. Individual chunks are sub-events within that span. The final parsed result is validated against the type parameter `[IncidentSummary]` after the stream completes.

---

## 7. Tools

### 7.1 Tool Design

Tools separate **contract** from **implementation**. The contract is what LLMs see (schema + description). The implementation is the wiring that executes the effect.

```
tool Stripe.CreateRefund {
  description: "Creates a refund for a customer charge via Stripe."

  input {
    customer_id: String  @description("Stripe customer ID")
    ticket_id: Uuid      @description("Internal support ticket ID")
    amount: Int          @description("Refund amount in cents") @min(1)
  }

  output {
    id: String
    amount: Int
    status: String
  }

  errors {
    StripeError
    RateLimitError
  }

  implement {
    let response = http.post("https://api.stripe.com/v1/refunds", json: {
      customer: input.customer_id,
      amount: input.amount,
      metadata: { ticket_id: input.ticket_id }
    })

    match response {
      Ok(r)  -> Ok({ id: r.body.id, amount: r.body.amount, status: r.body.status })
      Err(e) -> Err(StripeError.from(e))
    }
  }
}
```

### 7.2 Why Separate Contract and Implementation

- **LLM tool calling:** The `input`, `output`, and `description` blocks auto-generate function-calling manifests for any LLM provider. The implementation is invisible to the LLM.
- **Testing:** You can mock a tool by replacing only the `implement` block. The contract stays the same.
- **Agent code generation:** An LLM generating code that *calls* a tool only needs to see the contract. It doesn't need to understand HTTP wiring.
- **Governance:** The contract is the reviewable, auditable surface. Implementation changes are operational; contract changes are API changes.

### 7.3 Tool Policies

Tools can carry policies that are enforced at runtime:

```
tool DangerousDelete {
  -- ... input/output ...

  policy {
    require_approval: true               -- human must approve before execution
    rate_limit: 10 per minute
    allowed_phases: [Phase.Cleanup]       -- only callable during specific agent phases
    audit_level: full                     -- log complete input/output (not just metadata)
  }

  implement { ... }
}
```

---

## 8. Handlers

Handlers are the entry points for external events. They follow the universal `keyword name signature block` pattern.

### 8.1 HTTP

```
handler http GET "/users/:id" (req) -> {
  let id = req.params.id       -- typed as String, parse explicitly
  let user = User.get!(Uuid.parse!(id))
  respond.json(200, user)
}

handler http POST "/users" (req) -> {
  let input = req.json[CreateUserRequest]?    -- parse and validate against type
  let user = User.create!(input)
  respond.json(201, user)
}
```

### 8.2 Queue / Topic

```
handler queue "billing.events" (msg) -> {
  idempotent(msg.id)              -- skip if already processed

  match msg.json[BillingEvent]? {
    BillingEvent.DisputeCreated(d) -> handle_dispute(d)
    BillingEvent.ChargeSucceeded(c) -> handle_charge(c)
    _ -> ack()
  }
}

handler topic "incident.created" (msg) -> {
  IncidentAgent.start(msg.data.incident_id)
}
```

### 8.3 Schedule

```
handler schedule "0 9 * * MON" (tick) -> {
  let report = generate_weekly_report()
  tool.call(Slack.PostMessage, { channel: "#ops", text: report })
}
```

---

## 9. Observability

### 9.1 Traces Are Automatic

Every handler invocation, agent phase transition, tool call, model invocation, and storage operation produces a structured trace span — automatically. No instrumentation code required.

A trace is a tree of spans:

```
Trace: handle_refund_request (trace_id: abc-123)
├── Span: http.handler POST /refunds (12ms)
│   ├── Span: store.get User (2ms)
│   ├── Span: agent.start RefundAgent (0ms)
│   │   ├── Span: phase.Analyze (1,203ms)
│   │   │   ├── Span: store.get Ticket (3ms)
│   │   │   └── Span: llm.json claude-opus-4-8 (1,198ms) [tokens: 340 in, 89 out, $0.002]
│   │   ├── Span: phase.Refund (456ms)
│   │   │   └── Span: tool.call Stripe.CreateRefund (453ms)
│   │   └── Span: phase.Done (0ms)
│   └── Span: event.emit RefundIssued (1ms)
└── Result: Ok (1,674ms total)
```

### 9.2 Trace Metadata

Every span carries:

- **Timing:** start, end, duration
- **Identity:** trace_id, span_id, parent_span_id, tenant_id, user_id
- **I/O summary:** sanitized request/response metadata (secrets redacted)
- **Cost:** for model calls, token counts and dollar cost
- **Outcome:** Ok/Err with typed error classification

### 9.3 Replay

Traces can be replayed in three modes:

- **Recorded:** All external I/O is replaced with recorded responses. Fully deterministic.
- **Live:** External I/O is re-executed against real services. Results may differ.
- **Hybrid:** Some I/O is recorded (e.g., model calls), some is live (e.g., DB reads). Useful for testing prompt changes against real data.

```
test "refund agent approves eligible ticket" {
  replay(trace: "abc-123", mode: recorded) {
    assert agent.final_phase == Phase.Done
    assert events.contains(RefundIssued { ticket_id: _, amount: 2500 })
    assert tool.calls["Stripe.CreateRefund"].count == 1
  }
}
```

---

## 10. Agent-Writability: Making It Concrete

This section addresses the explicit design decisions made to optimize Skein for LLM code generation.

### 10.1 Syntax Properties That Help LLMs

| Property | Design Choice | Why It Helps |
|----------|--------------|-------------|
| Regularity | One structural pattern for all constructs | LLM learns one template, applies everywhere |
| No ambiguity | No operator overloading, no implicit conversions | Token prediction is more confident |
| No sugar | No shorthand alternatives | Generated code is always canonical |
| Explicit types at boundaries | All function signatures are typed | LLM has clear specification to target |
| Consistent delimiters | Always braces, always commas | No "sometimes semicolons" confusion |
| Named everything | No anonymous lambdas | LLM can refer to and reason about all code by name |
| Small keyword set | ~25 keywords total | Entire vocabulary fits in a paragraph |

### 10.2 Structured Compiler Errors

Compiler errors are emitted as structured JSON so an LLM can parse them, understand the issue, and generate a fix:

```json
{
  "errors": [
    {
      "code": "E0012",
      "severity": "error",
      "message": "Capability 'http.out' required but not declared",
      "location": { "file": "billing.skein", "line": 45, "col": 5 },
      "context": "http.post(\"https://api.stripe.com/v1/refunds\", ...)",
      "fix_hint": "Add 'capability http.out(\"api.stripe.com\")' to the module or handler",
      "fix_code": "capability http.out(\"api.stripe.com\")"
    }
  ]
}
```

The `fix_hint` and `fix_code` fields are designed for LLM consumption. An agent editing Skein code can read the error, apply the suggested fix, and recompile — in a tight loop.

### 10.3 Capability Blocks as Specifications

When a human wants an LLM to generate a Skein module, they can provide a capability block as a "constitution" — a set of constraints that the generated code must operate within:

```
-- Human provides this spec:
module InvoiceProcessor {
  capability http.out("api.stripe.com", methods: [GET])
  capability store.table("invoices", ops: [read, write])
  capability model("anthropic", "claude-opus-4-8")
  capability tool.use(Slack.PostMessage)
}

-- LLM generates the implementation.
-- The compiler guarantees the implementation stays within bounds.
```

This is a fundamentally different relationship between human and AI than "generate code and hope it's safe." The human defines the sandbox; the LLM fills it in; the compiler enforces the boundaries.

### 10.4 Type-Driven Code Generation

Because every type auto-derives schemas, an LLM generating a tool or handler only needs to define the types to get:

- Input validation
- JSON serialization/deserialization
- LLM function-calling manifests
- Database schema (for stored types)
- Documentation

This dramatically reduces the surface area of "things an LLM can get wrong."

### 10.5 The Spec-in-Context Promise

The full Skein specification, including grammar, type rules, standard library signatures, and 50 canonical examples, targets approximately 80K tokens. This leaves 48K tokens in a 128K context window for the specific task at hand (user requirements, existing code, compiler errors).

The spec is distributed as a single file: `SKEIN_SPEC.md`. Any LLM can be given this file as context and immediately generate valid Skein code.

---

## 11. The Standard Library

The standard library is intentionally minimal — only what's needed for cloud agent services, nothing more.

### 11.1 Core Modules

```
-- Data
String, Int, Float, Bool, List, Map, Set, Option, Result, Uuid, Instant, Duration

-- I/O (all capability-controlled)
Http          -- http.get, http.post, http.put, http.delete
Store         -- store.get, store.put, store.query, store.delete, store.migrate
Memory        -- memory.put, memory.get, memory.delete, memory.list
Topic         -- topic.publish
Queue         -- queue.publish
Event         -- event.emit, event.log

-- AI
Llm           -- llm.chat, llm.json, llm.stream, llm.embed, llm.rerank
Tool          -- tool.call, tool.list, tool.schema

-- Concurrency
Task          -- task.spawn, task.await, task.cancel
Stream        -- stream.map, stream.filter, stream.collect, stream.buffer

-- Platform
Trace         -- trace.current, trace.annotate
Config        -- config.get (runtime configuration)
Secret        -- secret.get (injected, never logged)
Idempotent    -- idempotent.key, idempotent.check
```

### 11.2 What's Deliberately Missing

No file system operations (cloud services don't have local disks). No raw TCP/UDP (use HTTP). No OS process spawning (use BEAM processes). No regex (use typed parsers). No date math beyond `Instant` and `Duration` (a deliberate simplification; use an Erlang library via FFI if you need calendrical math).

Every omission reduces the spec size and removes a category of bugs that LLMs would otherwise generate.

---

## 12. Error Model

### 12.1 Two Error Paths

**Expected errors** use `Result[T, E]` — the function signature tells you what can go wrong and you handle it with `match`, `?`, or `!`.

**Unexpected errors** crash the process — the supervisor restarts it, and the trace captures what happened. No try/catch, no exception handling, no defensive programming against the unknowable.

### 12.2 Error Types

Each domain defines its error types as enums:

```
enum RefundError {
  NotEligible(reason: String)
  AmountExceedsCharge(charged: Int, requested: Int)
  AlreadyRefunded(refund_id: String)
  StripeFailure(code: String, message: String)
  Timeout
}
```

### 12.3 LLM-Specific Errors

Model calls have a rich error type that supports intelligent retry:

```
enum LlmError {
  ParseFailed(raw: String, expected_type: String, parse_error: String)
  Refused(reason: String)
  RateLimit(retry_after: Duration)
  Timeout(elapsed: Duration)
  ContentFiltered(filter: String)
  InvalidSchema(violations: List[SchemaViolation])
  ProviderError(code: String, message: String)
}
```

An agent that encounters `LlmError.ParseFailed` can inspect the `raw` output, understand the `parse_error`, and retry with an adjusted prompt — all within the type system.

---

## 13. Testing

### 13.1 Built-In Test Construct

Tests are a first-class language construct, not an external framework:

```
test "refund agent denies ineligible ticket" {
  let ticket = Ticket.mock(status: TicketStatus.Closed, age_days: 90)

  let agent = RefundAgent.run_sync(
    ticket_id: ticket.id,
    customer_id: "cust_123",
    stubs: {
      "Stripe.CreateRefund": fn _ -> Err(StripeError.new("not_eligible"))
    }
  )

  assert agent.final_phase == Phase.Done
  assert agent.events |> List.none(&is_refund_issued)
  assert agent.memory.get("decision").action == Action.Deny
}
```

### 13.2 Scenario Tests

For agent evaluation, scenario tests define input conditions and expected behavioral properties:

```
scenario "high-value refund requires approval" {
  given {
    ticket: Ticket.mock(amount: 50000)    -- $500
    model_response: { action: "approve", amount: 50000 }
  }

  expect {
    events.contains(ApprovalRequested { ... })
    agent.suspended == true
    tool.calls["Stripe.CreateRefund"].count == 0   -- not called before approval
  }
}
```

### 13.3 Golden Trace Tests

Pin a set of traces as "golden" for regression gating:

```
golden "standard refund flow" from trace "abc-123" {
  -- Re-run with recorded I/O; assert same outcomes
  assert same_phases
  assert same_events
  assert same_tool_calls
}
```

---

## 14. Supervision and Deployment

### 14.1 Supervisors

```
supervisor Main {
  child HttpServer { restart: permanent }
  child QueueConsumer("billing.events") { restart: permanent }
  child AgentPool(RefundAgent) { max: 5000, restart: transient }
  child Scheduler { restart: permanent }

  strategy: one_for_one
  max_restarts: 10 per 60s
}
```

### 14.2 Agent Pools

Agent pools are dynamic supervisors that spawn agent instances on demand:

```
-- In a handler:
AgentPool.start_child(RefundAgent, ticket_id: ticket.id, customer_id: customer.id)

-- The pool enforces max concurrency, queues overflow, and tracks instance lifecycle.
```

### 14.3 Deployment Model

```bash
skein build              # Compile to BEAM bytecode, package as OTP release
skein test               # Run all tests (unit, scenario, golden, replay)
skein deploy             # Push to managed platform (or your cluster)
skein deploy --canary 5  # 5% canary with automatic rollback on error spike
```

---

## 15. Interop

### 15.1 Erlang/Elixir FFI

```
-- Call an Erlang function with explicit type boundary
extern fn crypto_hash(algo: Atom, data: Binary) -> Binary
  = :crypto.hash/2

-- Call an Elixir module
extern fn json_decode(input: String) -> Result[Dynamic, JsonError]
  = Jason.decode/1
```

FFI calls are *not* capability-controlled (they bypass the effect system). This is intentional — interop is an escape hatch for advanced users, not the default path.

### 15.2 OTP Behaviours

Advanced users can drop down to raw GenServer or Supervisor behaviours:

```
-- Implement a custom GenServer directly (advanced, not recommended for most use cases)
behaviour MyCustomServer : GenServer {
  on init(args) -> { ... }
  on handle_call(msg, from, state) -> { ... }
  on handle_cast(msg, state) -> { ... }
}
```

---

## 16. Complete Example: Incident Triage Service

This puts everything together in a realistic service.

```
module IncidentTriage {
  capability http.in
  capability http.out("api.github.com")
  capability store.table("incidents")
  capability topic.publish("incident.created")
  capability topic.consume("incident.created")
  capability model("anthropic", "claude-opus-4-8")
  capability tool.use(Jira.CreateIssue, Slack.PostMessage)
  capability memory.kv("incidents")

  -- Types

  type Incident {
    id: Uuid
    source: String
    severity: Severity
    title: String
    details: String
    created_at: Instant
  }

  enum Severity { Critical, High, Medium, Low }

  type TriageSummary {
    root_cause: String
    confidence: Float @min(0.0) @max(1.0)
    recommended_action: Action
    slack_message: String
  }

  enum Action { CreateTicket, Escalate, Ignore }

  -- HTTP Handler

  handler http POST "/incidents" (req) -> {
    let incident = Incident.create!(req.json[Incident]?)
    topic.publish("incident.created", { id: incident.id })
    respond.json(202, { id: incident.id })
  }

  -- Topic Handler

  handler topic "incident.created" (msg) -> {
    TriageAgent.start(msg.data.id)
  }

  -- Agent

  agent TriageAgent {
    state {
      incident_id: Uuid
      phase: Phase
    }

    enum Phase {
      Gather    -> [Summarize]
      Summarize -> [Act, Escalate, Done]
      Act       -> [Done]
      Escalate  -> [Done]
      Done      -> []
    }

    on start(incident_id: Uuid) -> {
      transition(Phase.Gather)
    }

    on phase(Phase.Gather) -> {
      let incident = Incident.get!(state.incident_id)
      let deploys = http.get("https://api.github.com/repos/koho/core/deployments")
      let recent = deploys?
        |> List.filter(fn d -> { d.created_at > incident.created_at - Duration.hours(6) })

      memory.put("context", { incident: incident, recent_deploys: recent })
      transition(Phase.Summarize)
    }

    on phase(Phase.Summarize) -> {
      let ctx = memory.get!("context")

      let summary = llm.json[TriageSummary](
        model: "claude-opus-4-8",
        system: "Analyze this incident and provide a triage summary. Be concise.",
        input: ctx
      )

      match summary {
        Ok(s) -> {
          memory.put("summary", s)
          match s.confidence > 0.8 {
            true  -> transition(Phase.Act)
            false -> transition(Phase.Escalate)
          }
        }
        Err(e) -> {
          emit TriageError { incident_id: state.incident_id, error: e }
          transition(Phase.Escalate)
        }
      }
    }

    on phase(Phase.Act) -> {
      let s = memory.get!("summary")

      match s.recommended_action {
        Action.CreateTicket -> {
          tool.call(Jira.CreateIssue, {
            title: "Incident: ${s.root_cause}",
            body: s.slack_message,
            priority: "high"
          })!
        }
        _ -> {}
      }

      tool.call(Slack.PostMessage, {
        channel: "#oncall",
        text: s.slack_message
      })!

      emit IncidentTriaged { incident_id: state.incident_id, action: s.recommended_action }
      transition(Phase.Done)
    }

    on phase(Phase.Escalate) -> {
      emit ApprovalRequested {
        incident_id: state.incident_id,
        reason: "Low confidence triage — needs human review"
      }
      suspend(reason: "Awaiting human triage review")
    }
  }

  -- Supervision

  supervisor Main {
    child HttpServer { restart: permanent }
    child TopicConsumer("incident.created") { restart: permanent }
    child AgentPool(TriageAgent) { max: 1000, restart: transient }

    strategy: one_for_one
    max_restarts: 20 per 60s
  }
}
```

---

## 17. Open Questions

These are genuine design tensions, not settled answers.

**Static vs. gradual typing.** The current design is fully static. A gradual alternative would let agents generate "quick and dirty" code that gets progressively typed. The tradeoff: static typing catches more errors at compile time (better for agent-generated code), but gradual typing lowers the barrier to getting *something* running.

**How much Erlang to expose.** The `extern` FFI is deliberately low-ceremony, which could encourage bypassing the capability system. Alternative: require FFI calls to declare capabilities too, even if they can't be verified statically.

**Agent persistence model.** Current design checkpoints agent state after each phase transition. Alternative: event-sourcing where agent state is reconstructed from an event log. Event-sourcing is more robust to schema changes but adds complexity.

**Multi-model orchestration.** Current design treats each `llm.*` call independently. Real agent systems often need to orchestrate across models (cheap model for classification, expensive model for generation, embedding model for retrieval). Should there be a first-class "model pipeline" construct?

**The name.** Skein means "a length of yarn loosely coiled and knotted" or "a tangled or complicated arrangement." The yarn/thread metaphor works for concurrent processes. The "tangled" meaning is... less ideal for a language that promises clarity. But it's memorable.

---

## Appendix: Design Decisions Summary

| Decision | Choice | Alternative Considered | Rationale |
|----------|--------|----------------------|-----------|
| No `if/else` | `match` only | `if/else` + `match` | One construct, zero ambiguity |
| No anonymous lambdas | Named functions + `&ref` | Closures | LLMs generate named code more reliably |
| No `return` keyword | Last expression is return value | Explicit `return` | Eliminates early-return bugs in generated code |
| No exceptions | `Result` + crash | try/catch | Two clear paths, no hidden control flow |
| Mutable agent state | Explicit state struct with transitions | Immutable state + event sourcing | Simpler for LLMs to generate; transitions are validated |
| Braces always | Mandatory `{ }` | Significant whitespace | Unambiguous parsing for both humans and LLMs |
| Capability-controlled effects | Compile + runtime enforcement | Runtime-only, or honor system | Critical for agent-generated code safety |
| Structured compiler errors | JSON with fix hints | Human-readable text only | Enables LLM self-correction loops |
| Single spec file | `SKEIN_SPEC.md` < 128K tokens | Scattered documentation | Enables "spec in context" for any LLM |
