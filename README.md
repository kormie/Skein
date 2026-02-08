# Skein

**A programming language where AI agents are first-class citizens.**

Skein compiles to BEAM bytecode and runs on the Erlang VM — the same battle-tested runtime behind WhatsApp, Discord, and millions of telecom systems. It's designed for building cloud services where reliability matters and AI agents do real work.

```
agent RefundAgent {
  capability model("anthropic", "claude-sonnet-4-5")
  capability tool.use("Stripe.CreateRefund")

  enum Phase {
    Analyze -> [Refund, Done]
    Refund  -> [Done, Failed]
    Failed  -> [Analyze]
    Done    -> []
  }

  on phase(Phase.Analyze) -> {
    let ticket = store.tickets.get!(state.ticket_id)
    let decision = llm.json[RefundDecision](
      model: "claude-sonnet-4-5",
      system: "Decide if this refund is warranted.",
      input: ticket
    )
    match decision.action {
      "approve" -> transition(Phase.Refund)
      "deny"    -> transition(Phase.Done)
    }
  }
}
```

> The compiler verifies every phase transition, every side effect, and every type contract — before a single line runs.

---

## Why Skein?

Most languages treat AI agents as library code running inside a general-purpose runtime. Skein treats them as the **primary abstraction**.

**Agents are state machines.** Phases, transitions, and terminal states are declared in the language and verified at compile time. Invalid transitions don't compile.

**Side effects require capabilities.** Every network call, database query, and LLM invocation must be declared upfront. This isn't just for safety — it gives you a complete manifest of what any piece of code can do.

**Types generate schemas.** Define a type once and Skein derives JSON encoders, LLM tool manifests, API contracts, and database migrations automatically. No serialization boilerplate.

**The entire spec fits in a context window.** The complete language specification is under 128K tokens. An LLM can hold all of Skein in memory and generate valid code reliably.

---

## Language at a Glance

### 12 constructs. One way to do things.

```
-- Bindings are immutable
let user = store.users.get!(id)

-- Pattern matching is the only conditional
match user.status {
  Active    -> process_order(user)
  Suspended -> respond.json(403, { "error": "account suspended" })
  Deleted   -> respond.json(404, { "error": "not found" })
}

-- Pipes compose operations
request.body
  |> validate[CreateOrderInput]
  |> enrich_with_inventory
  |> store.orders.put!
  |> respond.json(201)
```

### Types as contracts

```
type Money {
  amount: Int       @min(0)
  currency: String  @one_of(["USD", "CAD", "EUR"])
}

type Pagination {
  page: Int      @min(1)
  per_page: Int  @min(1) @max(100) @default(25)
}

enum OrderStatus {
  Pending
  Confirmed(confirmed_at: Instant)
  Shipped(tracking_id: String)
  Delivered(delivered_at: Instant)
  Cancelled(reason: String)
}
```

Annotations like `@min`, `@max`, and `@one_of` flow through to JSON Schema, validation, and LLM tool definitions — all generated from this single source of truth.

### Capabilities declare intent

```
module PaymentService {
  capability http.in
  capability http.out("api.stripe.com", methods: [POST])
  capability store.table("transactions")
  capability model("anthropic", "claude-sonnet-4-5")

  -- The compiler enforces these boundaries.
  -- Code that tries to call an undeclared endpoint won't compile.
}
```

### Handlers respond to the world

```
handler http POST "/refunds" (req) -> {
  let input = req.json[RefundRequest]?
  RefundAgent.start(ticket_id: input.ticket_id, customer_id: input.customer_id)
  respond.json(202, { "status": "processing" })
}

handler queue "billing.events" (msg) -> {
  idempotent(msg.id)
  match msg.json[BillingEvent]? {
    BillingEvent.ChargeSucceeded(c) -> record_charge(c)
    BillingEvent.DisputeCreated(d)  -> handle_dispute(d)
  }
}

handler schedule "0 9 * * MON" (tick) -> {
  generate_weekly_report() |> send_to_slack("#ops")
}
```

### Tools separate contract from implementation

```
tool Stripe.CreateRefund {
  description: "Creates a refund via Stripe."

  input {
    customer_id: String  @description("Stripe customer ID")
    amount: Int          @description("Amount in cents") @min(1)
  }

  output {
    id: String
    amount: Int
    status: String
  }

  policy {
    require_approval: true
    rate_limit: 10 per minute
    audit_level: full
  }

  implement { ... }
}
```

LLM tool-calling manifests are auto-generated from the contract. The implementation can be swapped or mocked independently.

### Automatic observability

Every operation produces structured trace spans with zero instrumentation code:

```
Trace: handle_refund_request (abc-123)
├── http.handler POST /refunds (12ms)
│   ├── store.get User (2ms)
│   ├── agent.start RefundAgent (0ms)
│   │   ├── phase.Analyze (1,203ms)
│   │   │   ├── store.get Ticket (3ms)
│   │   │   └── llm.json claude-sonnet-4-5 (1,198ms) [$0.002]
│   │   ├── phase.Refund (456ms)
│   │   │   └── tool.call Stripe.CreateRefund (453ms)
│   │   └── phase.Done (0ms)
│   └── event.emit RefundIssued (1ms)
└── Result: Ok (1,674ms total)
```

Traces can be replayed for testing: fully recorded, live against real services, or a hybrid of both.

---

## Design Decisions

| Decision | What Skein does | Why |
|---|---|---|
| No `if/else` | `match` only | One control flow construct, zero ambiguity |
| No anonymous lambdas | Named functions + `&ref` | Named code is easier to trace and reason about |
| No exceptions | `Result[T, E]` + OTP crash semantics | Two clear paths, no hidden control flow |
| Braces always | Mandatory `{ }` | Unambiguous parsing for humans and machines |
| Structured errors | JSON with `fix_hint` and `fix_code` | Enables automated self-correction loops |
| Spec fits in 128K tokens | Entire language in one document | Any LLM can hold the full language in context |

---

## Getting Started

### Prerequisites

- Erlang/OTP 27+
- Elixir 1.17+

### Build and test

```bash
git clone https://github.com/kormie/Skein.git
cd Skein
mix deps.get
mix test
```

### Compile a Skein program

```bash
# Once the CLI is complete:
mix skein.compile path/to/file.skein
```

---

## Project Status

Skein is in active development. The compiler and runtime are being built in phases:

| Phase | Goal | Status |
|-------|------|--------|
| **1** | **Hello BEAM** — end-to-end compilation pipeline | In progress |
| 2 | Type system — named types, enums, type checking, schema derivation | Planned |
| 3 | Capabilities — declared effects, compile-time + runtime checking | Planned |
| 4 | HTTP handlers — routing, request/response, running server | Planned |
| 5 | Storage — typed records, migrations | Planned |
| 6 | Agents — state machines, LLM calls, tools, memory | Planned |
| 7 | Testing & CLI — test constructs, replay, golden traces | Planned |

Phase 1 target: take a `.skein` file, lex it, parse it, generate Core Erlang, compile to `.beam`, and call the resulting function from Elixir.

---

## Architecture

```
Source (.skein)
    │
    ▼
  Lexer ──────── Source text → Token stream
    │
    ▼
  Parser ─────── Token stream → AST
    │
    ▼
  Analyzer ───── AST → Annotated AST (types, capabilities, transitions)
    │
    ▼
  CodeGen ────── Annotated AST → Core Erlang
    │
    ▼
  BEAM ───────── Core Erlang → .beam bytecode (via OTP)
```

The compiler is written in Elixir. The runtime is a set of OTP behaviours — agents run as supervised `gen_statem` processes, HTTP goes through Bandit + Plug, storage through Ecto.

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

---

## Documentation

| Document | What it covers |
|----------|----------------|
| [Language Specification](docs/SKEIN_SPEC.md) | Every syntax rule, type rule, and standard library function |
| [Architecture](docs/ARCHITECTURE.md) | Compiler pipeline, runtime design, supervision tree |
| [Implementation Plan](docs/IMPLEMENTATION_PLAN.md) | Phased build plan with acceptance criteria |
| [Design Rationale](docs/skein_first_principles.md) | First principles and the "why" behind every decision |
| [Documentation Site](https://kormie.github.io/Skein/) | Published docs with LLM-friendly endpoints |

**For LLMs:** The documentation site publishes machine-readable formats at [`/llms.txt`](https://kormie.github.io/Skein/llms.txt) and [`/llms-full.txt`](https://kormie.github.io/Skein/llms-full.txt).

---

## Contributing

The project uses an Elixir umbrella structure under `apps/`:

- **`skein_compiler`** — Lexer, parser, analyzer, code generator
- **`skein_runtime`** — OTP behaviours, LLM client, storage, tracing
- **`skein_cli`** — Command-line tooling

```bash
mix test          # Run all tests
mix format        # Format code
```

TDD is mandatory — write tests before or alongside implementation. See [CLAUDE.md](CLAUDE.md) for the full set of conventions.
