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

Built with NimbleParsec for performance and composability.

Token categories:

```elixir
# Keywords (reserved, cannot be used as identifiers)
:module, :fn, :let, :match, :type, :enum, :handler, :agent, :tool,
:capability, :supervisor, :test, :scenario, :golden, :on, :emit,
:transition, :stop, :suspend, :resume, :true, :false

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

**Pass 1: Name resolution**
- Build symbol table of all modules, types, enums, functions, agents, tools
- Resolve identifiers to their declarations
- Error on undefined references

**Pass 2: Type checking**
- Infer types for `let` bindings using local inference
- Check function call argument types against declared parameter types
- Check function return expressions against declared return types
- Validate `match` arm patterns against the subject type
- Check `match` exhaustiveness (all enum variants covered)
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

### 1.5 Code Generator (`Skein.CodeGen.CoreErlang`)

**Input:** Annotated AST
**Output:** Core Erlang module (via `:cerl` AST nodes)

The code generator translates Skein constructs to Core Erlang + Skein runtime calls:

| Skein Construct | Core Erlang / Runtime Target |
|-----------------|------------------------------|
| `module` | Core Erlang module |
| `fn` | Core Erlang function |
| `let` | Core Erlang `let` binding |
| `match` | Core Erlang `case` |
| `pipe` | Nested function calls |
| `!` (unwrap) | `case` with error branch calling `:erlang.error/1` |
| `?` (propagate) | `case` with error branch returning `{:error, e}` |
| String interpolation | Binary construction (`<<>>`) |
| `type` fields | Erlang map construction |
| `handler` | Function registered with `Skein.Runtime.Handler` |
| `agent` | Module implementing `Skein.Runtime.Agent` behaviour |
| `tool` | Module registered with `Skein.Runtime.Tool.Registry` |
| `capability` | Metadata stored in module attributes |
| `emit` | Call to `Skein.Runtime.Event.emit/2` |
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

Compiled Skein agents implement the `Skein.Runtime.Agent` behaviour, which wraps `gen_statem`.

```elixir
defmodule Skein.Runtime.Agent do
  @callback init(args :: map()) :: {:ok, initial_state :: map()}
  @callback handle_phase(phase :: atom(), state :: map()) :: phase_result()

  @type phase_result ::
    {:transition, atom(), map()} |       # move to new phase with updated state
    {:stop, :normal, map()} |             # graceful shutdown
    {:suspend, String.t(), map()} |       # pause for human-in-the-loop
    {:error, term()}                      # crash (supervisor handles restart)
end
```

The generated module translates Skein's `on phase(Phase.X) -> { ... }` blocks into `handle_phase/2` clauses.

**State checkpointing:** After each phase transition, the agent's state is serialized and persisted to the memory store. On supervisor restart, the agent resumes from the last checkpoint.

**Instance ID:** Each agent instance gets a unique ID (UUID) that scopes its memory namespace. The ID is stable across restarts.

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

### 2.3 Trace Collector (`Skein.Runtime.Trace`)

Built on OpenTelemetry, with Skein-specific span attributes.

```elixir
defmodule Skein.Runtime.Trace do
  def with_span(name, attributes, fun) do
    span = start_span(name, attributes)
    try do
      result = fun.()
      end_span(span, :ok, result_meta(result))
      result
    rescue
      e ->
        end_span(span, :error, %{exception: inspect(e)})
        reraise e, __STACKTRACE__
    end
  end
end
```

Span attributes include:
- `skein.trace_id`, `skein.span_id`, `skein.parent_span_id`
- `skein.module`, `skein.handler`, `skein.agent`, `skein.phase`
- `skein.tool_name`, `skein.model`, `skein.capability`
- `skein.tenant_id` (when multi-tenancy is implemented)
- `skein.tokens_in`, `skein.tokens_out`, `skein.cost` (for LLM calls)
- `skein.duration_ms`

Traces are stored in an ETS table for the local trace viewer, and optionally exported to an external collector.

### 2.4 LLM Client (`Skein.Runtime.LLM`)

Provider-agnostic LLM client with schema-constrained decoding.

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

Compiled tool declarations register with the tool registry at application startup.

```elixir
defmodule Skein.Runtime.Tool.Registry do
  # Tools register at startup
  def register(name, %{input_schema: _, output_schema: _, implement: _, policy: _})

  # Agents call tools through this
  def call(name, args, opts \\ [])

  # Generate LLM function-calling manifest for a set of tools
  def manifest(tool_names, provider: :anthropic | :openai)
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
  # Agent-scoped operations (scope derived from process context)
  def put(key, value)
  def get(key)
  def get!(key)    # raises on missing
  def delete(key)
  def list(prefix \\ "")

  # Cross-agent read (requires explicit capability)
  def read(agent_name, instance_id, key)
end
```

Backed by ETS for ephemeral (fast, lost on restart) or Postgres/SQLite for durable (slower, survives restart). Agents use durable memory by default; the runtime handles serialization.

---

## 3. Supervision Tree

```
Skein.Application (Application)
├── Skein.Runtime.Supervisor (Supervisor, one_for_one)
│   ├── Skein.Runtime.Store (GenServer — Ecto repo manager)
│   ├── Skein.Runtime.Memory (GenServer — KV store manager)
│   ├── Skein.Runtime.Tool.Registry (GenServer — tool registration)
│   ├── Skein.Runtime.Trace.Collector (GenServer — trace storage)
│   ├── Skein.Runtime.Capability.Store (ETS-backed capability cache)
│   ├── Skein.Runtime.HTTP.Server (Bandit — HTTP listener)
│   └── Skein.Runtime.AgentSupervisor (DynamicSupervisor — agent pool)
│       ├── Agent instance 1 (gen_statem)
│       ├── Agent instance 2 (gen_statem)
│       └── ...
```

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
