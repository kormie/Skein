defmodule Skein.EffectABI do
  @moduledoc """
  The **authoritative effect-ABI registry** (C1/#296): the single source of
  truth for every effect method's capability, parameters, analyzer return
  type, runtime dispatch target, and spec §6 signature.

  Everything that used to be a hand-maintained copy is now *derived* from
  `entries/0`:

  - the analyzer's `@effect_namespaces` / `@effect_methods` /
    `@effect_return_types` / `@effect_param_names` / `@effect_param_types` /
    `@effect_optional_params` / `@provider_contracts` tables,
  - codegen's generic runtime-module map and scoped-capability-kind map,
  - the spec §6 signature lines (drift-tested both directions by
    `effect_abi_spec_test.exs` — editing §6 without editing this registry, or
    vice versa, is a CI failure),
  - the runtime ABI-matrix shape tests in `skein_runtime`
    (`effect_abi_matrix_test.exs` — every method's live success/failure shape,
    completeness enforced against this registry).

  ## Field reference

  - `:ns` / `:method` — the Skein-source spelling `ns.method(...)`.
  - `:capability` — required capability kind (`nil` = always available).
  - `:scoped` — how the capability parameter scopes calls: `:label` (the
    compiler threads the declared label into the call — process/timer/event,
    spec §3.2), `:namespace` (memory key prefixing), `:host` (declared HTTP
    host allow-list), or `nil`.
  - `:params` — positional source parameters (`%{name, type, optional}`).
    Only trailing params may be optional.
  - `:named_args` — whether calls may pass these params by name (Pass 0a).
  - `:return` — the analyzer's declared type, or `:from_type_param` when the
    call form carries the type (`llm.json[T]`). `:dynamic` components are the
    spec-sanctioned dynamic seams (payloads; error shapes are C2's).
  - `:runtime` — `{module, function}` the compiled call dispatches to. The
    generated arity varies with threading (scope labels, capability lists),
    so the ABI-matrix test derives it per entry.
  - `:dispatch` — `:generic` (codegen's shared effect clause uses the module
    map) or `:special` (memory/llm/tool have dedicated codegen handlers).
  - `:spec_lines` — the exact signature lines of SKEIN_SPEC.md §6.

  ## Unit-returning effects

  `-> ()` in the spec lowers to the bare atom `:ok` at runtime and types as
  `:dynamic` in the analyzer (there is no unit type in the surface language);
  `trace.annotate` is the only remaining `()` effect and it cannot fail.
  `uuid.new()`/`instant.now()` cannot fail either and return their value
  bare (no `Result`).

  Special forms that are not `ns.method(...)` calls — `emit` (§6.7), agent
  lifecycle `transition`/`stop`/`suspend` (§6.8), `idempotent(key)` (§6.9),
  `req.json[T]` and `respond.*` (handler-scoped) — are outside this registry.
  """

  @type param :: %{name: String.t(), type: term(), optional: boolean()}
  @type entry :: %{
          ns: String.t(),
          method: String.t(),
          capability: String.t() | nil,
          scoped: :label | :namespace | :host | nil,
          params: [param()],
          named_args: boolean(),
          return: term(),
          runtime: {module(), atom()},
          dispatch: :generic | :special,
          spec_lines: [String.t()]
        }

  @entries [
    # ── 6.1 HTTP ─────────────────────────────────────────────────────────
    %{
      ns: "http",
      method: "get",
      capability: "http.out",
      scoped: :host,
      params: [%{name: "url", type: :string, optional: false}],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Http", :get},
      dispatch: :generic,
      spec_lines: ["http.get(url: String) -> Result[HttpResponse, HttpError]"]
    },
    %{
      ns: "http",
      method: "post",
      capability: "http.out",
      scoped: :host,
      params: [
        %{name: "url", type: :string, optional: false},
        %{name: "json", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Http", :post},
      dispatch: :generic,
      spec_lines: ["http.post(url: String, json: Map) -> Result[HttpResponse, HttpError]"]
    },
    %{
      ns: "http",
      method: "put",
      capability: "http.out",
      scoped: :host,
      params: [
        %{name: "url", type: :string, optional: false},
        %{name: "json", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Http", :put},
      dispatch: :generic,
      spec_lines: ["http.put(url: String, json: Map) -> Result[HttpResponse, HttpError]"]
    },
    %{
      ns: "http",
      method: "patch",
      capability: "http.out",
      scoped: :host,
      params: [
        %{name: "url", type: :string, optional: false},
        %{name: "json", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Http", :patch},
      dispatch: :generic,
      spec_lines: ["http.patch(url: String, json: Map) -> Result[HttpResponse, HttpError]"]
    },
    %{
      ns: "http",
      method: "delete",
      capability: "http.out",
      scoped: :host,
      params: [%{name: "url", type: :string, optional: false}],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Http", :delete},
      dispatch: :generic,
      spec_lines: ["http.delete(url: String) -> Result[HttpResponse, HttpError]"]
    },

    # ── 6.3 Memory ───────────────────────────────────────────────────────
    %{
      ns: "memory",
      method: "put",
      capability: "memory.kv",
      scoped: :namespace,
      params: [
        %{name: "key", type: :string, optional: false},
        %{name: "value", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Memory", :put},
      dispatch: :special,
      spec_lines: ["memory.put(key: String, value: T) -> Result[T, MemoryError]"]
    },
    %{
      ns: "memory",
      method: "get",
      capability: "memory.kv",
      scoped: :namespace,
      params: [%{name: "key", type: :string, optional: false}],
      named_args: true,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Memory", :get},
      dispatch: :special,
      spec_lines: ["memory.get(key: String) -> Result[T, NotFound]"]
    },
    %{
      ns: "memory",
      method: "delete",
      capability: "memory.kv",
      scoped: :namespace,
      params: [%{name: "key", type: :string, optional: false}],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Memory", :delete},
      dispatch: :special,
      spec_lines: ["memory.delete(key: String) -> Result[String, MemoryError]"]
    },
    %{
      ns: "memory",
      method: "list",
      capability: "memory.kv",
      scoped: :namespace,
      params: [%{name: "prefix", type: :string, optional: false}],
      named_args: true,
      return: {:list, :string},
      runtime: {:"Elixir.Skein.Runtime.Memory", :list},
      dispatch: :special,
      spec_lines: ["memory.list(prefix: String) -> List[String]"]
    },

    # ── 6.4 LLM ──────────────────────────────────────────────────────────
    %{
      ns: "llm",
      method: "chat",
      capability: "model",
      scoped: nil,
      params: [
        %{name: "model", type: :string, optional: false},
        %{name: "system", type: :string, optional: false},
        %{name: "input", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Llm", :chat},
      dispatch: :special,
      spec_lines: [
        "llm.chat(model: String, system: String, input: T) -> Result[String, LlmError]"
      ]
    },
    %{
      ns: "llm",
      method: "json",
      capability: "model",
      scoped: nil,
      params: [
        %{name: "model", type: :string, optional: false},
        %{name: "system", type: :string, optional: false},
        %{name: "input", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: :from_type_param,
      runtime: {:"Elixir.Skein.Runtime.Llm", :json},
      dispatch: :special,
      spec_lines: ["llm.json[T](model: String, system: String, input: U) -> Result[T, LlmError]"]
    },
    %{
      ns: "llm",
      method: "stream",
      capability: "model",
      scoped: nil,
      params: [
        %{name: "model", type: :string, optional: false},
        %{name: "system", type: :string, optional: false},
        %{name: "input", type: :dynamic, optional: false},
        %{name: "on_chunk", type: {:fn, [:string], :dynamic}, optional: true}
      ],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Llm", :stream},
      dispatch: :special,
      spec_lines: [
        "llm.stream(model: String, system: String, input: T) -> Result[String, LlmError]",
        "llm.stream(model: String, system: String, input: T, on_chunk) -> Result[String, LlmError]"
      ]
    },
    %{
      ns: "llm",
      method: "embed",
      capability: "model",
      scoped: nil,
      params: [
        %{name: "model", type: :string, optional: false},
        %{name: "input", type: :string, optional: false}
      ],
      named_args: true,
      return: {:result, {:list, :float}, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Llm", :embed},
      dispatch: :special,
      spec_lines: ["llm.embed(model: String, input: String) -> Result[List[Float], LlmError]"]
    },

    # ── 6.5 Tools ────────────────────────────────────────────────────────
    # Tool calls take a tool NAME (an identifier, not a value) plus an args
    # map — named-argument rewriting does not apply.
    %{
      ns: "tool",
      method: "call",
      capability: "tool.use",
      scoped: nil,
      params: [
        %{name: "name", type: :dynamic, optional: false},
        %{name: "args", type: :dynamic, optional: false}
      ],
      named_args: false,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Tool", :call},
      dispatch: :special,
      spec_lines: ["tool.call(name: ToolName, args: Map) -> Result[Map, ToolError]"]
    },
    %{
      ns: "tool",
      method: "list",
      capability: "tool.use",
      scoped: nil,
      params: [],
      named_args: false,
      return: {:result, {:list, :dynamic}, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Tool", :list},
      dispatch: :special,
      spec_lines: ["tool.list() -> Result[List[ToolInfo], ToolError]"]
    },
    %{
      ns: "tool",
      method: "schema",
      capability: "tool.use",
      scoped: nil,
      params: [%{name: "name", type: :dynamic, optional: false}],
      named_args: false,
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Tool", :schema},
      dispatch: :special,
      spec_lines: ["tool.schema(name: ToolName) -> Result[Map, ToolError]"]
    },

    # ── 6.6 Topics and Queues ────────────────────────────────────────────
    %{
      ns: "topic",
      method: "publish",
      capability: "topic.publish",
      scoped: nil,
      params: [
        %{name: "name", type: :string, optional: false},
        %{name: "data", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Topic", :publish},
      dispatch: :generic,
      spec_lines: ["topic.publish(name: String, data: T) -> Result[String, PublishError]"]
    },
    %{
      ns: "queue",
      method: "publish",
      capability: "queue.publish",
      scoped: nil,
      params: [
        %{name: "name", type: :string, optional: false},
        %{name: "data", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Queue", :publish},
      dispatch: :generic,
      spec_lines: ["queue.publish(name: String, data: T) -> Result[String, PublishError]"]
    },

    # ── 6.10 Trace and Event Store ───────────────────────────────────────
    %{
      ns: "trace",
      method: "annotate",
      capability: nil,
      scoped: nil,
      params: [
        %{name: "key", type: :string, optional: false},
        %{name: "value", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: :dynamic,
      runtime: {:"Elixir.Skein.Runtime.Trace", :annotate},
      dispatch: :generic,
      spec_lines: ["trace.annotate(key: String, value: String) -> ()"]
    },
    %{
      ns: "event",
      method: "log",
      capability: "event.log",
      scoped: :label,
      params: [
        %{name: "name", type: :string, optional: false},
        %{name: "data", type: :dynamic, optional: false}
      ],
      named_args: true,
      return: {:result, :string, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.EventStore", :log},
      dispatch: :generic,
      spec_lines: ["event.log(name: String, data: T) -> Result[String, String]"]
    },

    # ── 6.11 Background Work ─────────────────────────────────────────────
    %{
      ns: "process",
      method: "spawn",
      capability: "process.spawn",
      scoped: :label,
      params: [
        %{name: "task", type: :string, optional: false},
        %{name: "work", type: {:fn, [], :dynamic}, optional: true}
      ],
      named_args: true,
      return: {:result, :dynamic, :string},
      runtime: {:"Elixir.Skein.Runtime.Process", :spawn},
      dispatch: :generic,
      spec_lines: [
        "process.spawn(task: String) -> Result[_, String]",
        "process.spawn(task: String, work) -> Result[_, String]"
      ]
    },
    %{
      ns: "timer",
      method: "after",
      capability: "timer",
      scoped: :label,
      params: [
        %{name: "delay_ms", type: :int, optional: false},
        %{name: "task", type: :string, optional: false},
        %{name: "work", type: {:fn, [], :dynamic}, optional: true}
      ],
      named_args: true,
      return: {:result, :string, :string},
      runtime: {:"Elixir.Skein.Runtime.Timer", :after},
      dispatch: :generic,
      spec_lines: [
        "timer.after(delay_ms: Int, task: String) -> Result[String, String]",
        "timer.after(delay_ms: Int, task: String, work) -> Result[String, String]"
      ]
    },
    %{
      ns: "timer",
      method: "interval",
      capability: "timer",
      scoped: :label,
      params: [
        %{name: "every_ms", type: :int, optional: false},
        %{name: "task", type: :string, optional: false},
        %{name: "work", type: {:fn, [], :dynamic}, optional: true}
      ],
      named_args: true,
      return: {:result, :string, :string},
      runtime: {:"Elixir.Skein.Runtime.Timer", :interval},
      dispatch: :generic,
      spec_lines: [
        "timer.interval(every_ms: Int, task: String) -> Result[String, String]",
        "timer.interval(every_ms: Int, task: String, work) -> Result[String, String]"
      ]
    },
    %{
      ns: "timer",
      method: "cancel",
      capability: "timer",
      scoped: :label,
      params: [%{name: "ref", type: :dynamic, optional: false}],
      named_args: true,
      return: {:result, :string, :string},
      runtime: {:"Elixir.Skein.Runtime.Timer", :cancel},
      dispatch: :generic,
      spec_lines: ["timer.cancel(ref: String) -> Result[String, String]"]
    },

    # ── 6.12 Nondeterminism ──────────────────────────────────────────────
    %{
      ns: "uuid",
      method: "new",
      capability: "uuid",
      scoped: nil,
      params: [],
      named_args: true,
      return: :uuid,
      runtime: {:"Elixir.Skein.Runtime.Uuid", :new},
      dispatch: :generic,
      spec_lines: ["uuid.new() -> Uuid"]
    },
    %{
      ns: "instant",
      method: "now",
      capability: "instant",
      scoped: nil,
      params: [],
      named_args: true,
      return: :instant,
      runtime: {:"Elixir.Skein.Runtime.Instant", :now},
      dispatch: :generic,
      spec_lines: ["instant.now() -> Instant"]
    }
  ]

  # ── 6.2 Store (per-table dispatch: store.<table>.<method>) ─────────────
  @store_methods_registry [
    %{
      method: "get",
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Store", :get},
      spec_lines: ["store.<table>.get(id: Uuid) -> Result[T, NotFound]"]
    },
    %{
      method: "put",
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Store", :put},
      spec_lines: ["store.<table>.put(record: T) -> Result[T, StoreError]"]
    },
    %{
      method: "delete",
      return: {:result, :dynamic, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Store", :delete},
      spec_lines: ["store.<table>.delete(id: Uuid) -> Result[Uuid, StoreError]"]
    },
    %{
      method: "query",
      return: {:result, {:list, :dynamic}, :dynamic},
      runtime: {:"Elixir.Skein.Runtime.Store", :query},
      spec_lines: ["store.<table>.query(filters: Map) -> Result[List[T], StoreError]"]
    }
  ]

  # Scenario provider contracts (spec §3.10, §4.3 rule 13). These are the
  # only capabilities with a runtime provider resolution point
  # (`Skein.Runtime.Nondeterminism`, `Http.dispatch/3`, `Llm.ProviderBackend`).
  @provider_contracts %{
    "uuid" => %{
      params: [],
      return: :uuid,
      signature: "implement() -> Uuid"
    },
    "instant" => %{
      params: [],
      return: :instant,
      signature: "implement() -> Instant"
    },
    "http.out" => %{
      params: [{:user_type, "HttpRequest"}],
      return: {:result, {:user_type, "HttpResponse"}, {:user_type, "HttpError"}},
      signature: "implement(req: HttpRequest) -> Result[HttpResponse, HttpError]"
    },
    "model" => %{
      params: [{:user_type, "LlmRequest"}],
      return: {:result, {:user_type, "LlmResponse"}, {:user_type, "LlmError"}},
      signature: "implement(req: LlmRequest) -> Result[LlmResponse, LlmError]"
    }
  }

  @doc "Every effect-method registry entry."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The store-method sub-registry (`store.<table>.<method>`)."
  @spec store_entries() :: [map()]
  def store_entries, do: @store_methods_registry

  @doc "Scenario provider contracts, keyed by capability kind."
  @spec provider_contracts() :: map()
  def provider_contracts, do: @provider_contracts

  # ── Derived views (the former hand-maintained copies) ──────────────────

  @doc "namespace => required capability kind (nil = always available)."
  @spec effect_namespaces() :: %{String.t() => String.t() | nil}
  def effect_namespaces do
    Map.new(@entries, fn e -> {e.ns, e.capability} end)
  end

  @doc "namespace => [method names] (source order)."
  @spec effect_methods() :: %{String.t() => [String.t()]}
  def effect_methods do
    @entries
    |> Enum.group_by(& &1.ns, & &1.method)
  end

  @doc """
  {namespace, method} => analyzer return type. Methods whose type comes
  from the call form (`llm.json[T]`) are omitted, matching the analyzer's
  dedicated resolution path.
  """
  @spec effect_return_types() :: map()
  def effect_return_types do
    for e <- @entries, e.return != :from_type_param, into: %{} do
      {{e.ns, e.method}, e.return}
    end
  end

  @doc "{namespace, method} => positional source param names (named-arg support)."
  @spec effect_param_names() :: map()
  def effect_param_names do
    for e <- @entries, e.named_args, into: %{} do
      {{e.ns, e.method}, Enum.map(e.params, & &1.name)}
    end
  end

  @doc "{namespace, method} => positional param types, aligned with the names."
  @spec effect_param_types() :: map()
  def effect_param_types do
    for e <- @entries, e.named_args, into: %{} do
      {{e.ns, e.method}, Enum.map(e.params, & &1.type)}
    end
  end

  @doc "{namespace, method} => names of the trailing optional params."
  @spec effect_optional_params() :: map()
  def effect_optional_params do
    for e <- @entries,
        optional = for(p <- e.params, p.optional, do: p.name),
        optional != [],
        into: %{} do
      {{e.ns, e.method}, optional}
    end
  end

  @doc "Store method names."
  @spec store_methods() :: [String.t()]
  def store_methods, do: Enum.map(@store_methods_registry, & &1.method)

  @doc "store method => analyzer return type."
  @spec store_return_types() :: map()
  def store_return_types do
    Map.new(@store_methods_registry, fn e -> {e.method, e.return} end)
  end

  @doc """
  namespace => runtime module for codegen's GENERIC effect dispatch.
  Namespaces with dedicated codegen handlers (memory/llm/tool) are omitted,
  matching the codegen clause structure.
  """
  @spec generic_runtime_modules() :: %{String.t() => module()}
  def generic_runtime_modules do
    for e <- @entries, e.dispatch == :generic, into: %{} do
      {e.ns, elem(e.runtime, 0)}
    end
  end

  @doc """
  namespace => capability kind for the namespaces whose capability parameter
  is a scope LABEL the compiler threads into each call (spec §3.2).
  Memory's namespace threading is handled by its dedicated codegen clause.
  """
  @spec scoped_label_capability_kinds() :: %{String.t() => String.t()}
  def scoped_label_capability_kinds do
    for e <- @entries, e.scoped == :label, into: %{} do
      {e.ns, e.capability}
    end
  end

  @doc "Every spec §6 signature line the registry pins (effects + store)."
  @spec spec_lines() :: [String.t()]
  def spec_lines do
    effect_lines = Enum.flat_map(@entries, & &1.spec_lines)
    store_lines = Enum.flat_map(@store_methods_registry, & &1.spec_lines)
    effect_lines ++ store_lines
  end
end
