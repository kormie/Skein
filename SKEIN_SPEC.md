# SKEIN_SPEC.md — Complete Language Specification

**Version 0.1 — February 2026**

This document is the single-file specification for Skein. It is designed to fit within an LLM context window alongside task-specific code and instructions.

---

## 1. Notation

- `monospace` = literal syntax
- `<angle>` = placeholder
- `[optional]` = may be omitted
- `a | b` = alternatives
- `...` = repetition

---

## 2. Lexical Structure

### 2.1 Comments

```
-- This is a comment (to end of line)
```

No block comments.

### 2.2 Identifiers

```
lower_ident  = [a-z][a-z0-9_]*      -- variables, functions, fields
UpperIdent   = [A-Z][A-Za-z0-9]*     -- types, modules, agents, enum variants
```

### 2.3 Keywords

```
module  fn  let  match  type  enum  handler  agent  tool  capability
supervisor  test  scenario  golden  on  emit  transition  stop  suspend
resume  true  false  implement  input  output  errors  policy  description
state  strategy  child  replay  given  expect  assert
```

### 2.4 Operators

```
=    ->    |>    !    ?    .    :    ,    @    &
+    -    *    /
==   !=   <    >    <=   >=
&&   ||
```

### 2.5 Delimiters

```
{  }  (  )  [  ]
```

### 2.6 Literals

```
integer     = [0-9][0-9_]*                        -- 42, 1_000_000
float       = [0-9]+\.[0-9]+                      -- 3.14
string      = "..." with ${expr} interpolation     -- "hello ${name}"
boolean     = true | false
```

---

## 3. Grammar

### 3.1 Program Structure

```
program     = module
module      = "module" UpperIdent "{" declaration* "}"
declaration = capability | fn_decl | type_decl | enum_decl | handler
            | agent | tool_decl | supervisor | test_decl
```

### 3.2 Capabilities

```
capability  = "capability" cap_kind "(" cap_params ")"
cap_kind    = "http.out" | "http.in" | "store.table" | "memory.kv"
            | "event.log" | "topic.publish" | "topic.consume"
            | "queue.publish" | "queue.consume" | "model"
            | "tool.use" | "process.spawn" | "timer"
cap_params  = (string | named_arg) ("," (string | named_arg))*
named_arg   = lower_ident ":" expr
```

### 3.3 Functions

```
fn_decl     = "fn" lower_ident "(" params ")" "->" type_expr block
params      = (param ("," param)*)?
param       = lower_ident ":" type_expr
```

### 3.4 Types

```
type_decl   = "type" UpperIdent "{" field* "}"
field       = lower_ident ":" type_expr annotation* [","]
annotation  = "@" lower_ident ["(" expr ")"]

type_expr   = UpperIdent                              -- simple type: String, Int
            | UpperIdent "[" type_expr ("," type_expr)* "]"  -- parameterized: Option[T], Result[T, E]
```

### 3.5 Enums

```
enum_decl   = "enum" UpperIdent "{" variant* "}"
variant     = UpperIdent [transition_decl] ["(" field* ")"]
transition_decl = "->" "[" UpperIdent ("," UpperIdent)* "]"
```

### 3.6 Handlers

```
handler     = "handler" handler_source handler_route? "(" lower_ident ")" "->" block
handler_source = "http" http_method | "queue" | "topic" | "schedule"
http_method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
handler_route = string
```

### 3.7 Agents

```
agent       = "agent" UpperIdent "{" agent_body "}"
agent_body  = (capability | state_decl | enum_decl | on_handler | fn_decl)*
state_decl  = "state" "{" field* "}"
on_handler  = "on" on_trigger "(" params ")" "->" block
on_trigger  = "start" | "phase" "(" UpperIdent "." UpperIdent ")"
```

### 3.8 Tools

```
tool_decl   = "tool" dotted_name "{" tool_body "}"
dotted_name = UpperIdent ("." UpperIdent)*
tool_body   = description_block? input_block output_block errors_block? policy_block? implement_block
description_block = "description:" string
input_block   = "input" "{" field* "}"
output_block  = "output" "{" field* "}"
errors_block  = "errors" "{" UpperIdent* "}"
policy_block  = "policy" "{" policy_entry* "}"
implement_block = "implement" block
```

### 3.9 Supervisors

```
supervisor  = "supervisor" UpperIdent "{" sup_body "}"
sup_body    = (child_decl | strategy_decl | max_restarts_decl)*
child_decl  = "child" expr ["{" named_arg* "}"]
strategy_decl = "strategy:" ("one_for_one" | "one_for_all" | "rest_for_one")
max_restarts_decl = "max_restarts:" integer "per" integer "s"
```

### 3.10 Tests

```
test_decl    = "test" string block
             | "scenario" string "{" given_block expect_block "}"
             | "golden" string "from" "trace" string block
given_block  = "given" "{" (lower_ident ":" expr)* "}"
expect_block = "expect" "{" assertion* "}"
assertion    = "assert" expr
```

### 3.11 Expressions

```
expr        = let_expr | match_expr | pipe_expr | emit_expr
            | transition_expr | respond_expr | call_expr
            | binary_op | unary_op | field_access | literal
            | ident | fn_ref | block

let_expr      = "let" pattern "=" expr
match_expr    = "match" expr "{" match_arm+ "}"
match_arm     = pattern "->" expr
pipe_expr     = expr "|>" call_expr
emit_expr     = "emit" UpperIdent "{" (lower_ident ":" expr)* "}"
transition_expr = "transition" "(" expr ")"
respond_expr  = "respond" "." lower_ident "(" expr* ")"
call_expr     = (ident | field_access) "(" args ")"
binary_op     = expr op expr
unary_op      = expr ("!" | "?")
field_access  = expr "." lower_ident
fn_ref        = "&" lower_ident
block         = "{" expr* "}"

args          = (expr ("," expr)*)? | (named_arg ("," named_arg)*)?
pattern       = ident | literal | UpperIdent ["(" pattern* ")"]
             | "(" pattern ("," pattern)+ ")"   -- tuple destructure
             | "_"                               -- wildcard
```

---

## 4. Type System

### 4.1 Built-in Types

| Type | Description | JSON Schema |
|------|-------------|-------------|
| `Int` | 64-bit integer | `{"type": "integer"}` |
| `Float` | 64-bit float | `{"type": "number"}` |
| `String` | UTF-8 string | `{"type": "string"}` |
| `Bool` | true/false | `{"type": "boolean"}` |
| `Uuid` | UUID v4 | `{"type": "string", "format": "uuid"}` |
| `Instant` | UTC timestamp | `{"type": "string", "format": "date-time"}` |
| `Duration` | Time span | `{"type": "string"}` |
| `Email` | Email address | `{"type": "string", "format": "email"}` |
| `Url` | URL | `{"type": "string", "format": "uri"}` |
| `Option[T]` | T or absent | field not in `required` |
| `Result[T, E]` | Ok(T) or Err(E) | — (not serialized directly) |
| `List[T]` | Ordered list | `{"type": "array", "items": {...}}` |
| `Map[K, V]` | Key-value map | `{"type": "object"}` |
| `Set[T]` | Unique set | `{"type": "array", "uniqueItems": true}` |

### 4.2 Constraint Annotations

| Annotation | Applies to | JSON Schema Effect |
|------------|-----------|-------------------|
| `@min(n)` | Int, Float | `"minimum": n` |
| `@max(n)` | Int, Float | `"maximum": n` |
| `@one_of([...])` | String | `"enum": [...]` |
| `@default(v)` | Any | `"default": v` |
| `@primary` | Field | — (storage: primary key) |
| `@unique` | Field | — (storage: unique index) |
| `@description(s)` | Field, Type | `"description": s` |

### 4.3 Type Checking Rules

1. All function parameters and return types must be explicitly annotated.
2. `let` bindings infer their type from the right-hand side.
3. `match` arms must all return the same type.
4. `match` on an enum must cover all variants (or include `_` wildcard).
5. `!` can only be applied to `Result[T, E]` — produces `T`.
6. `?` can only be applied to `Result[T, E]` — enclosing function must return `Result[_, E]`.
7. `Option[T]` fields are not included in the `required` list of generated JSON schemas.
8. Pipe `|>` threads the left expression as the first argument to the right function call.

---

## 5. Standard Library

### 5.1 String

```
String.length(s: String) -> Int
String.slice(s: String, start: Int, length: Int) -> String
String.contains(s: String, sub: String) -> Bool
String.split(s: String, delimiter: String) -> List[String]
String.trim(s: String) -> String
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.starts_with(s: String, prefix: String) -> Bool
String.ends_with(s: String, suffix: String) -> Bool
String.replace(s: String, pattern: String, replacement: String) -> String
```

### 5.2 Int

```
Int.parse(s: String) -> Result[Int, ParseError]
Int.to_string(n: Int) -> String
Int.abs(n: Int) -> Int
Int.min(a: Int, b: Int) -> Int
Int.max(a: Int, b: Int) -> Int
Int.clamp(n: Int, low: Int, high: Int) -> Int
```

### 5.3 Float

```
Float.parse(s: String) -> Result[Float, ParseError]
Float.to_string(f: Float) -> String
Float.round(f: Float, decimals: Int) -> Float
Float.ceil(f: Float) -> Int
Float.floor(f: Float) -> Int
```

### 5.4 List

```
List.length(l: List[T]) -> Int
List.map(l: List[T], f: &(T -> U)) -> List[U]
List.filter(l: List[T], f: &(T -> Bool)) -> List[T]
List.reduce(l: List[T], init: U, f: &(U, T -> U)) -> U
List.find(l: List[T], f: &(T -> Bool)) -> Option[T]
List.first(l: List[T]) -> Option[T]
List.last(l: List[T]) -> Option[T]
List.head(l: List[T]) -> Option[T]
List.tail(l: List[T]) -> List[T]
List.take(l: List[T], n: Int) -> List[T]
List.drop(l: List[T], n: Int) -> List[T]
List.sort(l: List[T]) -> List[T]
List.sort_by(l: List[T], f: &(T -> U)) -> List[T]
List.reverse(l: List[T]) -> List[T]
List.flatten(l: List[List[T]]) -> List[T]
List.concat(a: List[T], b: List[T]) -> List[T]
List.contains(l: List[T], item: T) -> Bool
List.any(l: List[T], f: &(T -> Bool)) -> Bool
List.all(l: List[T], f: &(T -> Bool)) -> Bool
List.none(l: List[T], f: &(T -> Bool)) -> Bool
List.zip(a: List[T], b: List[U]) -> List[(T, U)]
List.uniq(l: List[T]) -> List[T]
List.count(l: List[T], f: &(T -> Bool)) -> Int
List.group_by(l: List[T], f: &(T -> K)) -> Map[K, List[T]]
```

### 5.5 Map

```
Map.get(m: Map[K, V], key: K) -> Option[V]
Map.get!(m: Map[K, V], key: K) -> V
Map.put(m: Map[K, V], key: K, value: V) -> Map[K, V]
Map.delete(m: Map[K, V], key: K) -> Map[K, V]
Map.keys(m: Map[K, V]) -> List[K]
Map.values(m: Map[K, V]) -> List[V]
Map.entries(m: Map[K, V]) -> List[(K, V)]
Map.size(m: Map[K, V]) -> Int
Map.has(m: Map[K, V], key: K) -> Bool
Map.merge(a: Map[K, V], b: Map[K, V]) -> Map[K, V]
Map.map_values(m: Map[K, V], f: &(V -> U)) -> Map[K, U]
Map.filter(m: Map[K, V], f: &(K, V -> Bool)) -> Map[K, V]
```

### 5.6 Set

```
Set.from(l: List[T]) -> Set[T]
Set.add(s: Set[T], item: T) -> Set[T]
Set.remove(s: Set[T], item: T) -> Set[T]
Set.contains(s: Set[T], item: T) -> Bool
Set.size(s: Set[T]) -> Int
Set.union(a: Set[T], b: Set[T]) -> Set[T]
Set.intersection(a: Set[T], b: Set[T]) -> Set[T]
Set.difference(a: Set[T], b: Set[T]) -> Set[T]
Set.to_list(s: Set[T]) -> List[T]
```

### 5.7 Option

```
Option.unwrap(o: Option[T], default: T) -> T
Option.map(o: Option[T], f: &(T -> U)) -> Option[U]
Option.flat_map(o: Option[T], f: &(T -> Option[U])) -> Option[U]
Option.is_some(o: Option[T]) -> Bool
Option.is_none(o: Option[T]) -> Bool
```

### 5.8 Result

```
Result.unwrap(r: Result[T, E], default: T) -> T
Result.map(r: Result[T, E], f: &(T -> U)) -> Result[U, E]
Result.map_err(r: Result[T, E], f: &(E -> F)) -> Result[T, F]
Result.flat_map(r: Result[T, E], f: &(T -> Result[U, E])) -> Result[U, E]
Result.is_ok(r: Result[T, E]) -> Bool
Result.is_err(r: Result[T, E]) -> Bool
Result.ok(value: T) -> Result[T, E]
Result.err(error: E) -> Result[T, E]
```

### 5.9 Uuid

```
Uuid.new() -> Uuid
Uuid.parse(s: String) -> Result[Uuid, ParseError]
Uuid.to_string(u: Uuid) -> String
```

### 5.10 Instant

```
Instant.now() -> Instant
Instant.parse(s: String) -> Result[Instant, ParseError]
Instant.to_string(i: Instant) -> String
Instant.add(i: Instant, d: Duration) -> Instant
Instant.subtract(i: Instant, d: Duration) -> Instant
Instant.diff(a: Instant, b: Instant) -> Duration
Instant.is_before(a: Instant, b: Instant) -> Bool
Instant.is_after(a: Instant, b: Instant) -> Bool
```

### 5.11 Duration

```
Duration.seconds(n: Int) -> Duration
Duration.minutes(n: Int) -> Duration
Duration.hours(n: Int) -> Duration
Duration.days(n: Int) -> Duration
Duration.to_seconds(d: Duration) -> Int
Duration.to_string(d: Duration) -> String
```

---

## 6. Effects API

All effect functions require a matching capability declaration.

### 6.1 HTTP Client

```
-- Requires: capability http.out(host)
http.get(url: String) -> Result[HttpResponse, HttpError]
http.post(url: String, json: Map) -> Result[HttpResponse, HttpError]
http.put(url: String, json: Map) -> Result[HttpResponse, HttpError]
http.delete(url: String) -> Result[HttpResponse, HttpError]

type HttpResponse { status: Int, body: Map, headers: Map[String, String] }
enum HttpError { Timeout, ConnectionFailed, Status(code: Int, body: String) }
```

### 6.2 Store

```
-- Requires: capability store.table(name)
store.<table>.get(id: Uuid) -> Result[T, NotFound]
store.<table>.put(record: T) -> Result[T, StoreError]
store.<table>.delete(id: Uuid) -> Result[Uuid, StoreError]
store.<table>.query(filters: Map) -> List[T]
```

### 6.3 Memory

```
-- Requires: capability memory.kv(namespace)
-- Inside agents: automatically scoped to agent instance
memory.put(key: String, value: T) -> Result[T, MemoryError]
memory.get(key: String) -> Result[T, NotFound]
memory.get!(key: String) -> T
memory.delete(key: String) -> Result[String, MemoryError]
memory.list(prefix: String) -> List[String]
```

### 6.4 LLM

```
-- Requires: capability model(provider, model_name)
llm.chat(model: String, system: String, input: T) -> Result[String, LlmError]
llm.json[T](model: String, system: String, input: U) -> Result[T, LlmError]
llm.stream[T](model: String, system: String, input: U, on_chunk: &(Chunk -> ())) -> Result[T, LlmError]
llm.embed(model: String, input: String) -> Result[List[Float], LlmError]

enum LlmError {
  ParseFailed(raw: String, expected_type: String, parse_error: String)
  Refused(reason: String)
  RateLimit(retry_after: Duration)
  Timeout(elapsed: Duration)
  ContentFiltered(filter: String)
  InvalidSchema(violations: List[String])
  ProviderError(code: String, message: String)
}
```

### 6.5 Tools

```
-- Requires: capability tool.use(tool_names)
tool.call(name: String, args: Map) -> Result[Map, ToolError]
tool.list() -> List[ToolInfo]
tool.schema(name: String) -> Map
```

### 6.6 Topics and Queues

```
-- Requires: capability topic.publish(name) / queue.publish(name)
topic.publish(name: String, data: T) -> Result[String, PublishError]
queue.publish(name: String, data: T) -> Result[String, PublishError]
```

### 6.7 Events

```
-- No capability required (events are always allowed)
emit <EventName> { field: value, ... }
```

### 6.8 Agent Lifecycle

```
-- Inside agents only
transition(phase: Phase) -> ()
stop() -> ()
suspend(reason: String) -> ()
resume(input: Map) -> ()
```

### 6.9 Idempotency

```
idempotent(key: String) -> ()   -- skip handler if key already processed
```

### 6.10 Trace

```
trace.annotate(key: String, value: String) -> ()  -- add metadata to current span
```

---

## 7. Compiler Errors

All errors are JSON-serializable with this structure:

```json
{
  "code": "E0012",
  "severity": "error",
  "message": "Human-readable description",
  "location": { "file": "service.skein", "line": 12, "col": 5 },
  "context": "The source line or expression in question",
  "fix_hint": "Explanation of how to fix",
  "fix_code": "Exact code to add or change"
}
```

### Error Codes

| Code | Category | Example |
|------|----------|---------|
| E0001 | Syntax | Unexpected token |
| E0002 | Syntax | Unterminated string |
| E0003 | Syntax | Invalid number literal |
| E0010 | Name | Undefined identifier |
| E0011 | Name | Duplicate definition |
| E0012 | Capability | Missing capability declaration |
| E0013 | Capability | Capability parameter mismatch |
| E0020 | Type | Type mismatch |
| E0021 | Type | Non-exhaustive match |
| E0022 | Type | Invalid `!` on non-Result |
| E0023 | Type | Invalid `?` on non-Result (or enclosing fn doesn't return Result) |
| E0024 | Type | Unknown type name |
| E0025 | Type | Constraint annotation on wrong type |
| E0030 | Agent | Invalid phase transition |
| E0031 | Agent | Unreachable phase |
| E0032 | Agent | Phase handler missing |
| E0033 | Agent | `transition()` outside agent |
| W0001 | Warning | Unused binding |
| W0002 | Warning | Unused capability |
| W0003 | Warning | Unreachable code after `stop()` |

---

## 8. Canonical Examples

### 8.1 Hello World

```
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }
}
```

### 8.2 HTTP API with Types

```
module UserService {
  capability http.in
  capability store.table("users")

  type User {
    id: Uuid @primary
    email: Email @unique
    name: String
    created_at: Instant
  }

  type CreateUserInput {
    email: Email
    name: String
  }

  handler http GET "/users/:id" (req) -> {
    let id = Uuid.parse!(req.params.id)
    let user = store.users.get(id)
    match user {
      Ok(u)           -> respond.json(200, u)
      Err(NotFound)   -> respond.json(404, { "error": "not found" })
    }
  }

  handler http POST "/users" (req) -> {
    let input = req.json[CreateUserInput]?
    let user = store.users.put({
      id: Uuid.new(),
      email: input.email,
      name: input.name,
      created_at: Instant.now()
    })!
    respond.json(201, user)
  }
}
```

### 8.3 Queue Worker

```
module BillingWorker {
  capability queue.consume("billing.events")
  capability http.out("api.stripe.com")
  capability store.table("transactions")

  enum BillingEvent {
    ChargeSucceeded(charge_id: String, amount: Int)
    DisputeCreated(dispute_id: String, charge_id: String)
  }

  handler queue "billing.events" (msg) -> {
    idempotent(msg.id)

    match msg.json[BillingEvent]? {
      BillingEvent.ChargeSucceeded(c) -> record_charge(c.charge_id, c.amount)
      BillingEvent.DisputeCreated(d)  -> handle_dispute(d.dispute_id, d.charge_id)
    }
  }

  fn record_charge(charge_id: String, amount: Int) -> Result[(), StoreError] {
    store.transactions.put({
      id: Uuid.new(),
      charge_id: charge_id,
      amount: amount,
      created_at: Instant.now()
    })
    |> Result.map(fn _ -> { () })
  }

  fn handle_dispute(dispute_id: String, charge_id: String) -> Result[(), HttpError] {
    let charge = http.get("https://api.stripe.com/v1/charges/${charge_id}")?
    -- process dispute logic
    Ok(())
  }
}
```

### 8.4 Agent with LLM and Tools

```
module RefundService {
  capability model("anthropic", "claude-sonnet-4-5")
  capability memory.kv("refund_sessions")
  capability tool.use("Stripe.CreateRefund")
  capability store.table("tickets")

  type RefundDecision {
    action: String @one_of(["approve", "deny"])
    amount: Int @min(0)
    reason: String
  }

  tool Stripe.CreateRefund {
    description: "Issue a refund via Stripe"

    input {
      customer_id: String @description("Stripe customer ID")
      amount: Int @description("Amount in cents") @min(1)
    }

    output {
      id: String
      amount: Int
      status: String
    }

    errors { StripeError }

    implement {
      let response = http.post("https://api.stripe.com/v1/refunds", json: {
        customer: input.customer_id,
        amount: input.amount
      })
      match response {
        Ok(r)  -> Ok({ id: r.body.id, amount: r.body.amount, status: r.body.status })
        Err(e) -> Err(StripeError.from(e))
      }
    }
  }

  agent RefundAgent {
    state {
      ticket_id: Uuid
      customer_id: String
      phase: Phase
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
      let ticket = store.tickets.get!(state.ticket_id)

      let decision = llm.json[RefundDecision](
        model: "claude-sonnet-4-5",
        system: "Decide if this ticket warrants a refund. Return JSON.",
        input: ticket
      )

      match decision {
        Ok(d) -> {
          memory.put("decision", d)
          match d.action {
            "approve" -> transition(Phase.Refund)
            "deny"    -> transition(Phase.Done)
          }
        }
        Err(e) -> {
          emit AnalysisError { ticket_id: state.ticket_id, error: e }
          transition(Phase.Failed)
        }
      }
    }

    on phase(Phase.Refund) -> {
      let d = memory.get!("decision")
      let result = tool.call("Stripe.CreateRefund", {
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
      suspend(reason: "Requires human review")
    }
  }

  supervisor Main {
    child HttpServer { restart: permanent }
    child AgentPool(RefundAgent) { max: 5000, restart: transient }
    strategy: one_for_one
    max_restarts: 10 per 60s
  }
}
```

### 8.5 Tests

```
module RefundServiceTest {
  test "greet returns hello message" {
    let result = Hello.greet("world")
    assert result == "Hello, world!"
  }

  test "refund agent approves eligible ticket" {
    let agent = RefundAgent.run_sync(
      ticket_id: Uuid.parse!("abc-123"),
      customer_id: "cust_456",
      stubs: {
        "llm.json": fn _ -> Ok({ action: "approve", amount: 2500, reason: "eligible" }),
        "Stripe.CreateRefund": fn args -> Ok({ id: "re_789", amount: args.amount, status: "succeeded" })
      }
    )

    assert agent.final_phase == Phase.Done
    assert agent.events |> List.any(fn e -> { match e { RefundIssued(_) -> true, _ -> false } })
  }

  scenario "high-value refund requires manual review" {
    given {
      ticket: { id: Uuid.new(), amount: 50000, status: "open" }
    }

    expect {
      assert agent.suspended == true
      assert agent.events |> List.none(fn e -> { match e { RefundIssued(_) -> true, _ -> false } })
    }
  }
}
```

---

*End of Skein Language Specification v0.1*
