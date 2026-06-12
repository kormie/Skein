# Skein Architecture

## 1. Compilation Pipeline

```
┌──────────────────────────────────────────────────────────────────┐
│                        Skein Compiler                            │
│                                                                  │
│  .skein ──▶ Lexer ──▶ Parser ──▶ Analyzer ──▶ CodeGen ──▶ .beam │
│           (tokens)   (AST)    (typed AST)  (Core Erlang)        │
│                                                                  │
│  Side outputs:                                                   │
│    ├── JSON Schema files (from types)                            │
│    ├── Tool manifests (from tool declarations)                   │
│    ├── Migration files (from store.table types)                  │
│    └── Structured errors (JSON)                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 1.1 Lexer (`Skein.Lexer`)

**Input:** UTF-8 source text
**Output:** List of `{token_type, location, value?}` tuples

Hand-written tokenizer using binary pattern matching — dependency-free, with precise error positions.

Token categories:

```elixir
# Keywords (reserved, cannot be used as identifiers)
:module, :fn, :let, :match, :type, :enum, :handler, :agent, :tool,
:capability, :supervisor, :test, :scenario, :golden, :on, :emit,
:transition, :stop, :suspend, :resume, :implement, :idempotent,
:true, :false

# Operators and punctuation
:eq,          # =
:arrow,       # ->
:pipe,        # |>
:bang,         # !
:question,    # ?
:dot,         # .
:colon,       # :
:comma,       # ,
:lbrace,      # {
:rbrace,      # }
:lparen,      # (
:rparen,      # )
:lbracket,    # [
:rbracket,    # ]
:at,          # @
:ampersand,   # &

# Comparison / arithmetic
:plus, :minus, :star, :slash,
:eq_eq, :neq, :lt, :gt, :lte, :gte,
:and_and, :or_or

# Literals
:int,         # 42
:float,       # 3.14
:string,      # "hello" (with interpolation segments)
:ident,       # variable/function names
:upper_ident, # Type/Module names (start with uppercase)

# Special
:comment,     # -- ...
:newline,     # significant only for error reporting
:eof
```

String tokens with interpolation are represented as a list of segments:

```elixir
# "Hello, ${name}!" becomes:
{:string, {1, 1}, [
  {:literal, "Hello, "},
  {:interpolation, {:ident, {1, 10}, "name"}},
  {:literal, "!"}
]}
```

Location is `{line, column}` — both 1-indexed.

### 1.2 Parser (`Skein.Parser`)

**Input:** Token list
**Output:** `{:ok, [Skein.AST.t()]}` or `{:error, [Skein.Error.t()]}`

Hand-written recursive descent parser. Rationale: better error messages and error recovery than parser generators. The grammar is small enough that hand-writing is tractable.

**Error recovery strategy:** On parse error, skip tokens until the next synchronization point (top-level keyword: `module`, `fn`, `type`, `handler`, `agent`, `tool`). This allows reporting multiple errors per compilation.

**Operator precedence (lowest to highest):**

| Level | Operators | Associativity |
|-------|-----------|---------------|
| 1 | `\|>` | Left |
| 2 | `\|\|` | Left |
| 3 | `&&` | Left |
| 4 | `==`, `!=` | None |
| 5 | `<`, `>`, `<=`, `>=` | None |
| 6 | `+`, `-` | Left |
| 7 | `*`, `/` | Left |
| 8 | `!`, `?` (postfix) | Postfix |
| 9 | `.` (field access) | Left |
| 10 | Function call `f(x)` | — |

### 1.3 AST (`Skein.AST`)

Every AST node is an Elixir struct with a `meta` field for source location. The AST is a direct representation of the source — no desugaring happens in the parser.

```elixir
defmodule Skein.AST do
  # Top-level declarations
  defmodule Module,     do: defstruct [:name, :capabilities, :declarations, :meta]
  defmodule Capability, do: defstruct [:kind, :params, :meta]
  defmodule Fn,         do: defstruct [:name, :params, :return_type, :body, :meta]
  defmodule TypeDecl,   do: defstruct [:name, :fields, :constraints, :meta]
  defmodule EnumDecl,   do: defstruct [:name, :variants, :transitions, :meta]
  defmodule Handler,    do: defstruct [:source, :method, :route, :param, :body, :meta]
  defmodule Agent,      do: defstruct [:name, :capabilities, :state, :phases, :handlers, :fns, :meta]
  defmodule ToolDecl,   do: defstruct [:name, :description, :input, :output, :errors, :policy, :implement, :meta]
  defmodule Supervisor, do: defstruct [:name, :children, :strategy, :max_restarts, :meta]
  defmodule Test,       do: defstruct [:description, :body, :meta]

  # Type nodes
  defmodule TypeRef,       do: defstruct [:name, :params, :meta]  # String, Option[T], Result[T, E]
  defmodule Field,         do: defstruct [:name, :type, :annotations, :meta]
  defmodule Variant,       do: defstruct [:name, :fields, :meta]  # enum variant
  defmodule Annotation,    do: defstruct [:name, :value, :meta]   # @min(0), @unique

  # Expression nodes
  defmodule Let,          do: defstruct [:name, :type, :value, :meta]
  defmodule Match,        do: defstruct [:subject, :arms, :meta]
  defmodule MatchArm,     do: defstruct [:pattern, :guard, :body, :meta]
  defmodule Call,         do: defstruct [:target, :args, :meta]        # fn(args) or module.fn(args)
  defmodule Pipe,         do: defstruct [:left, :right, :meta]
  defmodule FieldAccess,  do: defstruct [:subject, :field, :meta]
  defmodule BinaryOp,     do: defstruct [:op, :left, :right, :meta]
  defmodule UnaryOp,      do: defstruct [:op, :operand, :meta]        # !, ?
  defmodule StringLit,    do: defstruct [:segments, :meta]             # with interpolation
  defmodule IntLit,       do: defstruct [:value, :meta]
  defmodule FloatLit,     do: defstruct [:value, :meta]
  defmodule BoolLit,      do: defstruct [:value, :meta]
  defmodule ListLit,      do: defstruct [:elements, :meta]
  defmodule MapLit,       do: defstruct [:entries, :meta]
  defmodule Block,        do: defstruct [:expressions, :meta]
  defmodule Identifier,   do: defstruct [:name, :meta]
  defmodule FnRef,        do: defstruct [:name, :meta]                 # &function_name
  defmodule Transition,   do: defstruct [:phase, :meta]
  defmodule Emit,         do: defstruct [:event_name, :fields, :meta]
  defmodule Respond,      do: defstruct [:status, :body, :meta]
end
```

### 1.4 Analyzer (`Skein.Analyzer`)

**Input:** AST
**Output:** Annotated AST (same structure, with type information added to `meta`) + collected errors

The analyzer runs multiple passes:

**Pass 0: Named argument resolution (desugaring)**
- Validate named call arguments (`f(b: 2, a: 1)`) against the callee's declared parameter names (same-module/agent fns and documented effect signatures)
- Rewrite every call into positional order — later passes and codegen only ever see positional arguments
- Error (E0026) on unknown/duplicate names, a positional argument after a named one, or named arguments on a callee without a known signature

**Pass 1: Name resolution**
- Build symbol table of all modules, types, enums, functions, agents, tools
- Resolve identifiers to their declarations
- Error on undefined references

**Pass 2: Type checking**
- Infer types for `let` bindings using local inference
- Check function call argument types against declared parameter types
- Check function return expressions against declared return types
- Validate `match` arm patterns against the subject type
- Check `match` guards: guard-safe expression subset (E0027) and `Bool` type, with pattern bindings in scope
- Check `match` exhaustiveness (all enum variants covered; guarded arms don't count as coverage)
- Validate `!` and `?` operators are used on `Result` types
- Validate constraint annotations against field types (`@min` only on numeric, etc.)

**Pass 3: Capability checking**
- Walk function bodies looking for effect calls (`http.*`, `store.*`, `memory.*`, `llm.*`, `tool.*`, `topic.*`, `queue.*`, `emit`)
- For each effect call, verify a covering capability is declared on the enclosing module/handler
- Verify capability parameters (e.g., HTTP host matches declared host pattern)

**Pass 4: Transition checking (agents only)**
- Extract phase enum with transition declarations
- For each `transition(Phase.X)` call in an `on phase(Phase.Y)` handler, verify `X` is in `Y`'s transition list
- Verify all non-terminal phases have at least one `transition()` call
- Warn on unreachable phases

**Nested agents.** Agents declared inside a module are analyzed with the
full agent pass suite using an env enriched with the module's types, enums,
and capabilities (module-level capabilities apply to the nested agent; the
agent's own declarations win on name collisions).

### 1.5 Code Generator (`Skein.CodeGen.CoreErlang`)

**Input:** Annotated AST
**Output:** Named BEAM binaries (via `:cerl` AST nodes) — one for the module
plus one per nested agent (`module Foo { agent Bar }` produces
`Skein.User.Foo` and `Skein.Agent.Foo.Bar`)

The code generator translates Skein constructs to Core Erlang + Skein runtime calls:

| Skein Construct | Core Erlang / Runtime Target |
|-----------------|------------------------------|
| `module` | Core Erlang module |
| `fn` | Core Erlang function |
| `let` | Core Erlang `let` binding |
| `match` | Core Erlang `case` |
| `match` arm guard (`if`) | Core Erlang clause guard |
| `pipe` | Nested function calls |
| `!` (unwrap) | `case` with error branch calling `:erlang.error/1` |
| `?` (propagate) | `case` with error branch returning `{:error, e}` |
| String interpolation | Binary construction (`<<>>`) |
| `type` fields | Erlang map construction |
| `handler http` | Function registered with `Skein.Runtime.Handler` |
| `handler queue` | Function dispatched by `Skein.Runtime.Queue` |
| `handler schedule` | Function triggered by `Skein.Runtime.Schedule` |
| `agent` | Module driven by `Skein.Runtime.Agent` (gen_statem) |
| `tool` | `__tools__/0` metadata + `__tool_impl_N__/1` exports, registered via `Skein.Runtime.Tool.register_module/1` |
| `capability` | Metadata stored in module attributes |
| `emit` | Event map in the handler result, appended to `Skein.Runtime.EventStore` |
| `transition` | Call to `gen_statem` state change |
| `store.*` | Calls to `Skein.Runtime.Store` |
| `memory.*` | Calls to `Skein.Runtime.Memory` |
| `http.*` | Calls to `Skein.Runtime.Http` |
| `llm.*` | Calls to `Skein.Runtime.LLM` |
| `tool.call` | Call to `Skein.Runtime.Tool.call/3` |
| `req.json[T]` | Call to `Skein.Runtime.Request.json/2` with compile-time JSON Schema |

**Core Erlang generation uses the `:cerl` module** to build AST nodes programmatically. This is safer than generating text. The final step calls `:compile.forms/2` to produce `.beam` bytecode.

```elixir
defmodule Skein.CodeGen.CoreErlang do
  def generate(annotated_ast) do
    core_module = to_core_module(annotated_ast)
    {:ok, _, beam_binary} = :compile.forms(core_module, [:from_core, :binary, :return_errors])
    {:ok, beam_binary}
  end
end
```

### 1.6 Schema Generator (`Skein.CodeGen.SchemaGen`)

A separate code generation pass produces JSON Schemas from type declarations and tool manifest files from tool declarations.

```elixir
# Type -> JSON Schema
Skein.CodeGen.SchemaGen.to_json_schema(%AST.TypeDecl{
  name: "RefundRequest",
  fields: [
    %AST.Field{name: "amount", type: %AST.TypeRef{name: "Int"}, annotations: [%AST.Annotation{name: "min", value: 0}]},
    %AST.Field{name: "reason", type: %AST.TypeRef{name: "Option", params: [%AST.TypeRef{name: "String"}]}}
  ]
})

# Produces:
%{
  "type" => "object",
  "required" => ["amount"],
  "properties" => %{
    "amount" => %{"type" => "integer", "minimum" => 0},
    "reason" => %{"type" => "string"}
  }
}
```

---

## 2. Runtime Architecture

The Skein runtime is an OTP application that provides behaviours, services, and infrastructure for compiled Skein programs.

```
┌─────────────────────────────────────────────────────────┐
│                    Skein Runtime                         │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ HTTP Server   │  │ Agent Pool   │  │ Queue/Topic  │  │
│  │ (Bandit+Plug) │  │ (DynSuperv)  │  │ Consumer     │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                  │          │
│  ┌──────▼─────────────────▼──────────────────▼───────┐  │
│  │              Handler / Agent Dispatch              │  │
│  └──────┬─────────────────┬──────────────────┬───────┘  │
│         │                 │                  │          │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼───────┐  │
│  │ Capability   │  │ Trace        │  │ Tool         │  │
│  │ Enforcer     │  │ Collector    │  │ Registry     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Store (Ecto) │  │ Memory (KV)  │  │ LLM Client   │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 2.1 Agent Behaviour (`Skein.Runtime.Agent`)

Compiled Skein agents are driven by `Skein.Runtime.Agent`, a `gen_statem` that calls into the generated module's exports:

```elixir
# Generated surface of a compiled agent module
start_link(args)                      # start the gen_statem with initial params
__phases__()                          # phase metadata: variants + valid transitions
__start_handler__(args, capabilities) # the on start(...) body
__phase_handler__(phase, state, capabilities) # the on phase(Phase.X) bodies, dispatched by phase atom
```

Handler results tell the state machine what to do next: transition to a phase, keep the current phase, stop, or suspend (pause for human-in-the-loop), and carry the events emitted during that invocation.

**Durability:** agent state lives only in the gen_statem process. Durable data goes through `memory.kv` writes and emitted events (appended to the EventStore); a restarted agent process starts fresh from its `on start` handler — there is no automatic state checkpoint/resume.

**Instance ID:** Each agent instance gets a unique 16-byte hex ID (via `:crypto.strong_rand_bytes/16`) stored in the process dictionary as `:skein_agent_instance_id`. The `Memory` module reads this transparently to prefix keys with `{agent_name}:{instance_id}:`, providing automatic isolation between concurrent instances. The `list` operation filters and unscopes keys so callers see only their own unprefixed key names.

### 2.2 Capability Enforcer (`Skein.Runtime.Capability`)

Runtime capability enforcement as a second layer behind compile-time checking.

```elixir
defmodule Skein.Runtime.Capability do
  # Called by runtime wrappers before executing effects
  def check!(module, capability_kind, params) do
    declared = get_capabilities(module)
    unless covers?(declared, capability_kind, params) do
      raise Skein.Runtime.CapabilityViolation,
        module: module,
        kind: capability_kind,
        params: params
    end
  end
end
```

Every runtime effect wrapper (HTTP, store, memory, LLM, tool) calls `Capability.check!/3` before executing.

**Scoped capability labels (spec §3.2):** for `process.spawn`, `timer`, and `event.log` the capability parameter names a scope label (pool/group/stream). Codegen threads the declared label into every generated runtime call as the first argument — `Process.spawn(pool, task, caps)`, `Timer.after(group, delay, task, caps)`, `EventStore.log(stream, name, data, caps)` — mirroring the `memory.kv` namespace threading. The shared `Capability.check_scoped/3` enforces the label: no capability of the kind blocks the call; a parameterless declaration is unscoped (presence-only); otherwise the call's label must exactly match a declared param (`nil` labels are blocked). The label is recorded on the trace span (`pool:`/`group:`) or stored event (`stream:`). The first declared capability of the kind wins; nested agents list their own capabilities before the module's, so an agent-level label overrides the module's inside the agent (E0017 forbids two declarations in one scope).

### 2.3 Unified Event Store (`Skein.Runtime.EventStore`)

All runtime events — effect spans, trace annotations, user-defined events, and memory state changes — flow through a single append-only event log backed by one ETS ordered set (`:skein_events`).

```elixir
defmodule Skein.Runtime.EventStore do
  # Append any event (auto-assigns id, timestamp, _key)
  @spec append(map()) :: :ok
  def append(event)

  # User-event entry point for compiled event.log() calls; the stream is
  # the scoped capability label threaded in by codegen (nil = unscoped)
  @spec log(String.t() | nil, String.t(), term(), list()) :: :ok | {:error, String.t()}
  def log(stream, event_name, data, capabilities)

  # Query by kind, namespace, or any field
  @spec query(keyword()) :: [map()]
  def query(filters)

  # Chronological snapshot for golden tests
  @spec snapshot() :: [map()]
  def snapshot()
end
```

Event kinds:
- `:http`, `:memory`, `:llm`, `:store`, `:tool`, `:process`, `:timer` — effect spans with timing
- `:annotation` — `trace.annotate(key, value)` markers
- `:user_event` — `event.log(name, data)` user-defined events
- `:state_change` — memory mutation audit trail (put/delete with key/value data)

Every event carries: `id` (unique hex), `timestamp` (monotonic µs), `kind`, and kind-specific fields.

Two modules provide domain-specific APIs on top of this store:
- **`Skein.Runtime.Trace`** — timing/instrumentation facade (`with_span/2`, `annotate/2`, `recent_spans/1`). All effect wrappers (HTTP, LLM, etc.) call `Trace.with_span` which delegates to `EventStore.append`.
- **`Skein.Runtime.Memory`** — scoped KV state with capability checking and ETS caching. Each mutation also appends a `:state_change` event, enabling event-sourced reconstruction via `Memory.rebuild_from_events/1`.

### 2.4 LLM Client (`Skein.Runtime.LLM`)

Provider-agnostic LLM client with schema-constrained decoding.

Backends are pluggable: a module implementing `Skein.Runtime.Llm.Backend`, or a `{module, config}` tuple for parameterized backends. `AnthropicBackend` is the production backend; `BedrockBackend` serves AWS Bedrock (Converse API with SigV4 request signing; credentials from config/env or the AWS credential chain — `AWS_PROFILE` files, IAM Identity Center / SSO via `Skein.Runtime.Llm.AwsSsoProvider` (the `aws sso login` token cache + `GetRoleCredentials`), EKS IRSA via `Skein.Runtime.Llm.AwsWebIdentityProvider`, ECS task roles, EC2 IMDSv2 — started on demand, cached, and refreshed; real token streaming via `converse-stream`, decoding AWS's binary event-stream framing with the pure `Skein.Runtime.Llm.EventStream` codec; `region`/`base_url` config, and a `model_map` for inference-profile IDs — ARN-form model IDs are rejected with a structured error); `OpenAiCompatibleBackend` serves dev traffic from any local server speaking `POST {base_url}/chat/completions` (oMLX, Ollama, LM Studio, llama.cpp, vLLM), with a `model_map` remapping capability model names to locally hosted ones so source never changes between environments. The active backend comes from the project's `skein.toml` `[llm]` / `[env.<name>.llm]` profile, resolved by `skein run`/`skein test` via `--env` or `SKEIN_ENV` (`Skein.CLI.Config`). Every llm trace span records the `backend` (and `base_url` for local servers) that served the call.

```elixir
defmodule Skein.Runtime.LLM do
  @callback chat(opts :: keyword()) :: {:ok, String.t()} | {:error, LlmError.t()}
  @callback json(schema :: map(), opts :: keyword()) :: {:ok, map()} | {:error, LlmError.t()}
  @callback stream(opts :: keyword()) :: {:ok, Enumerable.t()} | {:error, LlmError.t()}
end
```

The `json` function:
1. Generates a JSON Schema from the Skein type parameter
2. Includes the schema in the LLM prompt (provider-specific format)
3. Parses the response as JSON
4. Validates against the schema
5. Returns `{:ok, decoded}` or `{:error, %LlmError{...}}` with rich error detail

```elixir
defmodule Skein.Runtime.LLM.Error do
  defstruct [:kind, :detail]

  @type t :: %__MODULE__{
    kind: :parse_failed | :refused | :rate_limit | :timeout |
          :content_filtered | :invalid_schema | :provider_error,
    detail: map()
  }
end
```

### 2.5 Tool Registry (`Skein.Runtime.Tool`)

Compiled tool declarations register with the tool registry (an ETS table owned by `EtsTables`) when their module is loaded — the CLI's compile/build/test/run paths call `register_module/1` after loading each module.

```elixir
defmodule Skein.Runtime.Tool do
  # Reads __tools__/0 metadata and registers each tool (idempotent)
  def register_module(mod)

  # Register a single tool by name/schema/implementation
  def register(name, schema, impl)

  # Callers invoke tools through this (capability-checked)
  def call(name, input, capabilities)

  # Registry reads
  def list(capabilities)
  def schema(name, capabilities)
end
```

Tool execution is wrapped in:
1. Capability check (is the caller allowed to use this tool?)
2. Policy enforcement (rate limit, approval requirement)
3. Input validation (against declared schema)
4. Trace span
5. Output validation
6. Result return

### 2.6 Store (`Skein.Runtime.Store`)

Thin wrapper around Ecto providing the `store.*` API.

Compile-time: Skein type declarations with `@primary` generate Ecto schema modules.
Runtime: `store.users.get(id)` compiles to `Skein.Runtime.Store.get(UsersSchema, id)`.

### 2.7 Memory (`Skein.Runtime.Memory`)

Scoped key-value store for agent working memory.

```elixir
defmodule Skein.Runtime.Memory do
  # The namespace comes from the memory.kv capability declaration;
  # codegen threads it into every call along with the capability list
  def put(namespace, key, value, capabilities)
  def get(namespace, key, capabilities)
  def get!(namespace, key, capabilities)   # raises on missing
  def delete(namespace, key, capabilities)
  def list(namespace, prefix, capabilities)
end
```

Backed by a single ETS table (`:skein_memory`, keyed `{namespace, key}`, owned by `EtsTables`) — fast and ephemeral. Inside a running agent, keys are additionally prefixed with the agent name and instance ID (read from the process dictionary) for isolation between concurrent instances. Each `memory.put`/`memory.delete` also appends a `:state_change` event to the EventStore, so memory state can be reconstructed from the event stream (`Memory.rebuild_from_events/1`); there is no durable database-backed memory in 1.0.

### 2.8 Queue Dispatch (`Skein.Runtime.Queue`)

GenServer-based in-memory message queue for compiled `handler queue` declarations. Manages subscriptions between queue names and handler functions, dispatching published messages asynchronously.

```elixir
defmodule Skein.Runtime.Queue do
  def subscribe(queue_name, module, handler_fn)
  def subscribe_fn(queue_name, fun)  # for testing
  def publish(queue_name, message)
  def list_queues()
  def reset_all()
end
```

**How it works:**
1. At startup, compiled queue handlers register via `subscribe/3`
2. `publish/2` dispatches messages to all subscribers asynchronously via GenServer cast
3. Each dispatch is wrapped in a trace span
4. Messages are delivered in order within a single queue
5. Messages to unsubscribed queues are silently dropped

### 2.9 Schedule Dispatch (`Skein.Runtime.Schedule`)

GenServer-based cron-style scheduling for compiled `handler schedule` declarations.

```elixir
defmodule Skein.Runtime.Schedule do
  def register(cron_expr, module, handler_fn)
  def register_fn(cron_expr, fun)  # for testing
  def trigger(cron_expr)
  def parse_cron(expr)
  def list_schedules()
  def reset_all()
end
```

**How it works:**
1. At startup, compiled schedule handlers register with their cron expression
2. `trigger/1` fires all handlers registered for a given expression (used in tests)
3. `parse_cron/1` validates 5-field cron expressions (minute, hour, day, month, weekday)
4. Each triggered handler is wrapped in a trace span

### 2.10 HTTP Server (`Skein.Runtime.Router` + Bandit)

Production-grade HTTP serving using Bandit + Plug.

- `Skein.Runtime.Router` dynamically builds a Plug module from compiled handler metadata (`__handlers__/0`)
- Routes HTTP requests to `__handler_N__/1` functions with parameter extraction
- Catches handler exceptions and returns 500 for graceful error handling
- Serves trace data at `GET /__skein/traces`
- `Skein.Runtime.Request.json/2` parses and validates request bodies against compile-time JSON Schema

### 2.11 LLM Streaming (`Skein.Runtime.Llm.stream/5`)

Streaming extension to the LLM client. Uses a callback-based API where chunks are delivered to the caller as they arrive, then assembled into the final response.

```elixir
Skein.Runtime.Llm.stream(model, system, input, on_chunk_fn, capabilities)
#=> {:ok, "assembled response text"}
```

The backend behaviour defines an optional `stream/3` callback returning `{:ok, [chunks]}`. For testing, pluggable backends (`StreamingTestBackend`, `DynamicStreamBackend`) return deterministic chunk sequences.

### 2.12 Replay Engine (`Skein.Runtime.Replay`)

Deterministic replay engine for golden trace tests. Loads recorded event stream files (JSON arrays of event objects from the unified EventStore) and replays them against the current runtime to verify behavior hasn't regressed.

```elixir
defmodule Skein.Runtime.Replay do
  # Load an event stream file from disk — returns parsed event list or raises
  @spec load_trace(String.t()) :: list(map())
  def load_trace(path)

  # Run fun with a process-scoped replay context — effect calls inside
  # are served from the recorded trace instead of real backends
  @spec with_replay(list(map()), (-> term())) :: term()
  def with_replay(trace, fun)

  # True when a replay context is active in the calling process
  @spec active?() :: boolean()
  def active?()

  # Consume the next recorded response of a kind, validating recorded
  # metadata (model/method/url/name) against the live call
  @spec next_response(atom(), map()) ::
          {:ok, term()} | {:mismatch, String.t()} | :exhausted | :no_replay
  def next_response(kind, expected)

  # Replay events, returning {event, result} tuples
  @spec replay(list(map())) :: list({map(), term()})
  def replay(spans)

  # Reconstruct memory state for a namespace from events
  @spec rebuild_memory(list(map()), String.t()) :: %{String.t() => any()}
  def rebuild_memory(events, namespace)
end
```

Supported event kinds: `handler`, `llm`, `memory`, `http`, `state_change`, `user_event`, `annotation`. Unknown kinds are passed through gracefully.

Used by compiled golden test functions:
1. `load_trace/1` reads and parses the JSON event stream file
2. Test body runs assertions against the loaded event data
3. `replay/1` re-dispatches events and collects results
4. `rebuild_memory/2` reconstructs memory state at any point from `:state_change` events

**Effect interception.** Inside `with_replay/2`, the effect runtimes consult the replay context before touching the outside world:

- **LLM** — `Skein.Runtime.Llm` swaps the configured backend for `Skein.Runtime.Llm.ReplayBackend`, which consumes recorded `llm` events (chat/json/stream/embed)
- **HTTP** — `Skein.Runtime.Http` serves recorded `status`/`response_body` instead of dialing the network
- **Tool calls** — `Skein.Runtime.Tool.call/3` returns the recorded `response` without executing the registered implementation (`tool.list`/`tool.schema` are local registry reads and re-execute live)

Consumption is sequential per kind and validated: the recorded event's `model`/`method`/`url`/`name` must match the live call, otherwise a structured "Replay mismatch" error is returned (the event is left unconsumed). An exhausted trace is an error too — replay never falls back to a real call. Capability checks run exactly as in live mode, before the replay context is consulted. To make live traces replayable, effect spans record full response payloads: `response` on `llm` and `tool` spans, `response_body` + `status` on `http` spans.

---

## 3. Supervision Tree

```
SkeinRuntime.Application (Application)
└── SkeinRuntime.Supervisor (Supervisor, one_for_one)
    ├── Skein.Runtime.EtsTables (GenServer — owns ALL named runtime ETS
    │     tables: memory, store, event store, timers, tool registry, ...)
    ├── Skein.Runtime.Process (DynamicSupervisor — process.spawn tasks)
    ├── Skein.Runtime.Queue (GenServer — queue dispatch)
    ├── Skein.Runtime.Topic (GenServer — pub/sub fan-out)
    ├── Skein.Runtime.Schedule (GenServer — cron dispatch)
    └── Skein.Runtime.Timer (GenServer — timers)
```

`EtsTables` starts first so sibling processes (and everything after app
start) can request named tables that outlive their callers. Store, Memory,
EventStore, and Tool are plain modules over those ETS tables, not
supervised processes of their own; `Skein.Runtime.Capability` checks are
pure functions over the capability lists codegen threads into each call.

Outside this tree:

- **Agents** run as `gen_statem` processes (`Skein.Runtime.Agent`), started
  by the host via the compiled module's `start_link/1` — there is no
  runtime-owned agent pool supervisor.
- **HTTP serving** is started by `skein run` via `Skein.Runtime.Server`
  (Bandit + the Plug router built from `__handlers__/0` metadata).

---

## 4. File Layout for a Compiled Skein Service

After `skein build`, a service is packaged as a standard OTP release:

```
_build/
├── rel/
│   └── my_service/
│       ├── bin/my_service          # Start script
│       ├── lib/
│       │   ├── my_service-0.1.0/   # Compiled .beam files from .skein sources
│       │   ├── skein_runtime-0.1.0/ # Skein runtime .beam files
│       │   └── ...                  # Elixir/OTP dependencies
│       └── releases/
│           └── 0.1.0/
│               ├── sys.config
│               └── vm.args
```

---

## 5. Test Infrastructure

Skein supports three built-in test constructs that compile to BEAM alongside application code:

### 5.1 Unit Tests (`test`)

```skein
test "addition works" {
  assert 1 + 1 == 2
}
```

Compiles to `__test_N__/0` functions. The `__tests__/0` metadata includes description and kind (`:test`).

### 5.2 Scenario Tests (`scenario`)

```skein
scenario "refund flow" {
  given {
    ticket_id: "t-123"
    amount: 100
  }
  expect {
    assert ticket_id == "t-123"
    assert amount == 100
  }
}
```

Variables from the `given` block are in scope during the `expect` block. Kind: `:scenario`.

### 5.3 Golden Trace Tests (`golden`)

```skein
golden "payment trace" from trace "traces/payment.json" {
  assert true == true
}
```

Loads a JSON trace file via `Skein.Runtime.Replay.load_trace/1`, then runs assertions. Kind: `:golden`.

### 5.4 CLI Integration

`skein test` discovers all compiled test functions, runs them, and reports results grouped by kind with pass/fail counts.

---

## 6. Language Server (`skein_lsp`)

The `skein_lsp` application provides IDE integration via the Language Server Protocol:

| Feature | Description |
|---------|-------------|
| Diagnostics | Real-time error reporting from the compiler pipeline |
| Completions | Keyword, type, function, and capability completions |
| Hover | Type information and documentation on hover |
| Semantic Tokens | Syntax highlighting via semantic token classification |
| Document Symbols | Outline view of modules, functions, types, agents, etc. |

Built on the `gen_lsp` library. The server re-compiles on document change and pushes diagnostics to the editor.

---

## 7. Distribution

The CLI (`skein_cli`) supports building standalone binaries via Burrito, a cross-compilation framework that packages BEAM releases into single executables.

**Supported targets:**
- Linux x86_64
- Linux aarch64
- macOS x86_64
- macOS aarch64 (Apple Silicon)

Build workflow: `mix release` + Burrito wrapping → single binary per platform. CI (GitHub Actions) automates this on version tags.
