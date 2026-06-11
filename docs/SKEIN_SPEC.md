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

Number literals are unsigned; negative numbers use the prefix `-` operator
(`-3`, `-1.5`), which is part of the expression grammar (§3.11), not the token.

---

## 3. Grammar

### 3.1 Program Structure

```
program     = module
module      = "module" UpperIdent "{" declaration* "}"
declaration = capability | fn_decl | type_decl | enum_decl | handler
            | agent | tool_decl | supervisor | test_decl
```

A program may span multiple files; each file declares one module (or agent).

#### Module Boundaries: Tools Are the Only Cross-Module Seam

A module's functions, types, enums, and handlers are **private to that module**.
There is no `import`, no `use`, and no qualified cross-module function call —
`OtherModule.fn_name(args)` is not Skein. The only way for code in one module to
invoke code in another is a tool call:

```
-- Module A: declare the grant, then call
capability tool.use(Billing.CreateRefund)
let result = tool.call(Billing.CreateRefund, { ticket_id: id })

-- Module B: declare and implement the tool
tool Billing.CreateRefund { input { ... } output { ... } implement { ... } }
```

Dotted calls with an uppercase head (`String.upcase(s)`) are reserved for the
standard library (§5), which is ambient — available in every module with no
declaration and no capability. The stdlib is part of the language, not a
cross-module mechanism; user modules cannot define functions in stdlib
namespaces or expose their own.

**Why tools-only.** This is a deliberate design decision, not an implementation
gap:

1. **Capability propagation stays explicit.** If module A could call
   `B.fetch_data()` and that function performs `http.out`, either A must
   re-declare B's capabilities (implementation details leak across the
   boundary; refactoring B breaks A's declarations) or the effect travels
   silently under B's declarations (reading A's source no longer tells you what
   effects a call can perform). Tools dissolve the dilemma:
   `capability tool.use(B.FetchData)` *is* the explicit cross-module grant,
   checked at the call site.
2. **Schemas at every boundary.** Tool inputs and outputs are typed and derive
   JSON Schema; every cross-module payload is validated.
3. **Everything is traceable.** Every tool call produces a trace span, so
   cross-module behavior is auditable from the event store.
4. **One way to do things.** A second seam — even one restricted to pure
   functions — would mean two cross-module mechanisms and a purity check in the
   analyzer.

**The trade-off, acknowledged.** Wrapping a pure helper (a string formatter, a
validator) in a tool is heavyweight: schema, registry, `Result`, trace span.
Skein accepts this cost. Pure-function sharing is served by the standard
library and by keeping a module and its helpers in one file — a module is
intended to fit in one context window: code, capabilities, tools, and tests
together. If field experience shows this failing for the agent-service domain,
the decision can be revisited; until then no import surface will be added.

**Compiler behavior.** A qualified call whose head is not a stdlib module is a
compile-time error (`E0016`) with a fix hint pointing at the tool seam — never
a silent unknown-symbol fallthrough.

**Testing.** Unit tests are co-located: `test`, `scenario`, and `golden` are
module-body declarations that live next to the code they exercise (§3.10,
§8.5). Cross-module (integration) tests exercise tools via `tool.call`, exactly
as production callers do, with `capability tool.use(...)` declared on the test
module.

**Packages (future).** A package will distribute modules whose public surface
is its tool declarations plus the JSON Schemas their types derive. The stdlib
remains the only ambient dependency.

### 3.2 Capabilities

```
capability  = "capability" cap_kind "(" cap_params ")"
cap_kind    = "http.out" | "http.in" | "store.table" | "memory.kv"
            | "event.log" | "topic.publish" | "topic.consume"
            | "queue.publish" | "queue.consume" | "schedule.trigger"
            | "model" | "tool.use" | "process.spawn" | "timer"
cap_params  = (string | identifier | named_arg) ("," (string | identifier | named_arg))*
              -- tool.use params are dotted identifiers: tool.use(Stripe.CreateRefund)
              -- other capabilities use strings: store.table("users"), model("anthropic", "claude-opus-4-8")
named_arg   = lower_ident ":" expr
identifier  = dotted_name
```

**Scoped capability labels.** For `memory.kv`, `event.log`, `process.spawn`,
and `timer`, the capability parameter names a *scope label* — a memory
namespace, event stream, process pool, or timer group. Call sites never
repeat the label: the compiler threads the declared label into every
generated runtime call, where it is enforced and recorded on the trace
span (the same model as `memory.kv`, which has always worked this way).
Because the label comes from the declaration, at most one capability of
each of these kinds may be declared per module or agent — a second
declaration is a compile error (E0017). A nested agent's declaration
overrides the enclosing module's for calls inside the agent. Declaring
the capability with no parameter leaves the effect unscoped
(presence-only enforcement).

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

Agents may be declared at the top level (one per file) or nested inside a
module's body. Agents do not declare `type` blocks — to use named types in an
agent (e.g. `llm.json[Decision]`), nest the agent inside the module that
declares them; the module's types and capabilities apply to the nested agent
(section 8.4). A nested agent compiles to its own BEAM module, namespaced
under the parent.

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
unary_op      = ("-" | "!") expr | expr ("!" | "?")
field_access  = expr "." lower_ident
fn_ref        = "&" lower_ident
block         = "{" expr* "}"

args          = (arg ("," arg)*)?               -- positional args first, then named
arg           = named_arg | expr
pattern       = ident | literal | UpperIdent ["(" pattern* ")"]
             | "(" pattern ("," pattern)+ ")"   -- tuple destructure (Planned — not implemented yet)
             | "_"                               -- wildcard
```

Prefix operators bind tighter than binary operators: `-2 + 3` is `(-2) + 3`,
and `-(2 + 3)` negates the sum. There is no negative-literal token; negative
numbers are written with prefix `-` applied to a literal. Negation requires an
`Int` or `Float` operand and preserves its type.

Call arguments may be passed by name: `f(name: value)`. Named arguments must
come after all positional arguments; together they must cover each remaining
parameter exactly once, in any order. The compiler resolves named arguments
against the callee's declared parameter names at compile time — there is no
runtime cost. Named arguments work for calls to functions in the same
module/agent and for effect calls with documented signatures (section 6);
unknown or duplicate names, a positional argument after a named one, and named
arguments on a callee without a known signature are all compile errors
(`E0026`). Patterns never use named arguments.

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
-- Inside agents: keys automatically prefixed with {agent_name}:{instance_id}:
-- This provides per-instance isolation — concurrent agent instances never collide.
-- memory.list() returns unscoped key names (prefix stripped).
-- Outside agent context: no scoping applied (backward compatible).
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
-- Requires: capability tool.use(ToolNames)
tool.call(name: ToolName, args: Map) -> Result[Map, ToolError]
tool.list() -> List[ToolInfo]
tool.schema(name: ToolName) -> Map
```

**Input validation:** `tool.call` validates input arguments against the tool's declared input schema before execution. Two schema formats are supported:
- Simple: `%{input: %{field_name => type}}` where type is `:int`, `:string`, `:float`, `:bool`
- JSON Schema: `%{"input_schema" => %{"type" => "object", "properties" => ..., "required" => [...]}}`

Invalid input returns a `ToolError` with `:validation_error` kind and a list of human-readable violation messages. Tools with no input schema skip validation. Extra fields beyond the schema are allowed; only declared fields are type-checked.

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

### 6.10 Trace and Event Store

All runtime events — effect spans, trace annotations, user-defined events (`event.log`), and memory state changes — are stored in a single unified event log. This enables querying, replay, and memory reconstruction from the event stream.

```
trace.annotate(key: String, value: String) -> ()  -- add metadata to current span
event.log(name: String, data: T) -> ()            -- record structured user event
```

`trace.annotate` requires no capability. `event.log` requires
`capability event.log(...)` — the capability parameter names the stream
the events are recorded to (a scoped capability label, §3.2); the call
carries only the event name and data.

Memory mutations (`memory.put`, `memory.delete`) automatically emit `:state_change` events, making memory state reconstructable from the event stream.

### 6.11 Background Work

```
-- Requires: capability process.spawn(pool)
process.spawn(task: String) -> ()         -- run a named supervised background task (no-op body)
process.spawn(task: String, work) -> ()   -- run `work` (a &fn reference) in the background

-- Requires: capability timer(group)
timer.after(delay_ms: Int, task: String) -> String     -- one-shot; returns a timer ref
timer.interval(every_ms: Int, task: String) -> String  -- repeating; returns a timer ref
timer.cancel(ref: String) -> ()
```

The pool/group capability parameter is a scoped capability label (§3.2):
the compiler threads it into each call and it appears on the trace span.
Crashes in spawned tasks are isolated by the runtime supervisor and never
take down the caller.

The optional `work` argument is a `&fn` reference to a zero-parameter
function in the same module; the function runs inside the supervised
task. Without `work`, the task is a named no-op recorded in the trace.
Timer tasks are named no-ops; attaching bodies to timers is Planned.

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
| E0014 | Tool | Tool name not declared in `capability tool.use` params |
| E0015 | Tool | Duplicate short tool name in `capability tool.use` params |
| E0016 | Name | Cross-module function call (functions are module-private; expose a tool instead) |
| E0017 | Capability | Duplicate scoped capability declaration (`memory.kv`, `event.log`, `process.spawn`, `timer` allow one per module or agent) |
| E0020 | Type | Type mismatch |
| E0021 | Type | Non-exhaustive match |
| E0022 | Type | Invalid `!` on non-Result |
| E0023 | Type | Invalid `?` on non-Result (or enclosing fn doesn't return Result) |
| E0024 | Type | Unknown type name |
| E0025 | Type | Constraint annotation on wrong type |
| E0026 | Type | Invalid named argument (unknown/duplicate name, positional after named, callee without named-argument support) |
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
      Err(NotFound)   -> respond.json(404, { error: "not found" })
    }
  }

  handler http POST "/users" (req) -> {
    let data = req.json[CreateUserInput]()?
    let user = store.users.put({
      id: Uuid.new(),
      email: data.email,
      name: data.name,
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

    match msg.json[BillingEvent]()? {
      BillingEvent.ChargeSucceeded(c) -> record_charge(c.charge_id, c.amount)
      BillingEvent.DisputeCreated(d)  -> handle_dispute(d.dispute_id, d.charge_id)
    }
  }

  fn record_charge(charge_id: String, amount: Int) -> Result[String, StoreError] {
    store.transactions.put({
      id: Uuid.new(),
      charge_id: charge_id,
      amount: amount,
      created_at: Instant.now()
    })
  }

  fn handle_dispute(dispute_id: String, charge_id: String) -> Result[String, HttpError] {
    let charge = http.get("https://api.stripe.com/v1/charges/${charge_id}")?
    trace.annotate("dispute_charge", charge.body)
    Ok("resolved")
  }
}
```

### 8.4 Agent with LLM and Tools

The agent is nested inside the module. It shares the module's types
(`RefundDecision`) and the module-level capabilities (`model`,
`store.table`) apply to it in addition to its own (`memory.kv`). The agent
compiles to its own BEAM module, `Skein.Agent.RefundService.RefundAgent`.

```
module RefundService {
  capability model("anthropic", "claude-opus-4-8")
  capability tool.use(Stripe.CreateRefund)
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
      let response = http.post("https://api.stripe.com/v1/refunds", {
        customer: customer_id,
        amount: amount
      })
      match response {
        Ok(r)  -> Ok({ id: r.body.id, amount: r.body.amount, status: r.body.status })
        Err(e) -> Err(StripeError.from(e))
      }
    }
  }

  supervisor Main {
    child HttpServer { restart: permanent }
    child AgentPool(RefundAgent) { max: 5000, restart: transient }
    strategy: one_for_one
    max_restarts: 10 per 60s
  }

  -- The refund agent: processes refund requests through multiple phases.
  -- Module-level capabilities (model, store.table) apply here too.
  agent RefundAgent {
    capability memory.kv("refund_sessions")

    state {
      ticket_id: String
      customer_id: String
    }

    enum Phase {
      Analyze  -> [Refund, Done, Failed]
      Refund   -> [Done, Failed]
      Failed   -> [Analyze]
      Done     -> []
    }

    on start(ticket_id: String, customer_id: String) -> {
      memory.put("ticket_id", ticket_id)
      memory.put("customer_id", customer_id)
      transition(Phase.Analyze)
    }

    on phase(Phase.Analyze) -> {
      let ticket_id = memory.get!("ticket_id")
      let ticket = store.tickets.get!(ticket_id)

      let decision = llm.json[RefundDecision](
        model: "claude-opus-4-8",
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
          emit AnalysisError { ticket_id: ticket_id }
          transition(Phase.Failed)
        }
      }
    }

    on phase(Phase.Refund) -> {
      let d = memory.get!("decision")
      let customer_id = memory.get!("customer_id")
      let result = tool.call(Stripe.CreateRefund, {
        customer_id: customer_id,
        amount: d.amount
      })

      match result {
        Ok(refund) -> {
          let tid = memory.get!("ticket_id")
          emit RefundIssued { ticket_id: tid, refund_id: refund.id }
          transition(Phase.Done)
        }
        Err(e) -> {
          let tid = memory.get!("ticket_id")
          emit RefundFailed { ticket_id: tid }
          transition(Phase.Failed)
        }
      }
    }

    on phase(Phase.Failed) -> {
      suspend("Requires human review")
    }

    on phase(Phase.Done) -> {
      stop()
    }
  }
}
```

### 8.5 Tests

Tests are co-located with the code they exercise (§3.1 Module Boundaries):
`test`, `scenario`, and `golden` are declarations in the module body, so the
function under test is in scope directly.

```
module RefundService {
  fn eligible(amount: Int) -> Bool {
    amount <= 5000
  }

  fn greeting(name: String) -> String {
    "Hello, ${name}!"
  }

  test "greeting returns hello message" {
    let result = greeting("world")
    assert result == "Hello, world!"
  }

  test "small refunds are eligible" {
    assert eligible(2500) == true
    assert eligible(9900) == false
  }

  scenario "high-value refund requires manual review" {
    given {
      ticket_id: "abc-123"
    }

    expect {
      -- Planned: agent.suspended, agent.events, and stub-based
      -- scenario testing are not yet implemented.
      -- For now, scenarios verify the given/expect structure parses.
      assert 1 == 1
    }
  }
}
```

Cross-module (integration) tests use the same seam as production code: declare
`capability tool.use(Other.Tool)` on the test's module and exercise the tool
with `tool.call` — there is no cross-module function access to test against.

> **Planned features for testing (not yet implemented):**
> - `Agent.run_sync()` — synchronous agent execution for tests
> - Stub declarations — mock LLM and tool responses
> - `agent.events` / `agent.final_phase` — event and phase introspection
> - Anonymous functions (`fn args -> ...`) as stub handlers

---

*End of Skein Language Specification v0.1*
