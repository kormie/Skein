defmodule Skein.Analyzer do
  @moduledoc """
  Semantic analyzer for Skein AST.

  Runs multiple passes:
  1. Name resolution (build symbol table, resolve identifiers)
  2. Type checking (verify types at boundaries, check match exhaustiveness)
  3. Capability checking (verify effect calls have covering capabilities)
  4. Transition checking (verify agent phase transitions are valid) — Phase 6
  5. Unused binding/capability/unreachable code detection

  ## Error Codes (aligned with SKEIN_SPEC.md section 7)

  ### Syntax (E000x) — emitted by lexer/parser
  - E0001: Unexpected token
  - E0002: Unterminated string
  - E0003: Invalid number literal

  ### Name Resolution (E001x)
  - E0010: Undefined identifier
  - E0011: Duplicate definition (same name declared twice in a scope)
  - E0012: Missing capability declaration
  - E0013: Capability parameter mismatch

  ### Tool (E001x)
  - E0014: Tool name not declared in `capability tool.use` params
  - E0015: Duplicate short tool name in `capability tool.use` params
  - E0017: Duplicate scoped capability declaration (memory.kv, event.log, process.spawn, timer)

  ### Type Checking (E002x)
  - E0020: Type mismatch (return type, match arm types, operator types, arity)
  - E0021: Non-exhaustive match (warning)
  - E0022: Invalid `!` on non-Result type
  - E0023: Invalid `?` on non-Result type (or enclosing fn doesn't return Result)
  - E0024: Unknown type name
  - E0025: Constraint annotation on wrong type
  - E0026: Invalid named argument (unknown/duplicate name, positional after named, callee without named-argument support)
  - E0027: Invalid guard expression (guards allow literals, bindings, field access, comparisons, boolean operators, and +/-/* arithmetic)

  ### Agent (E003x)
  - E0030: Invalid phase transition
  - E0031: Unreachable phase (warning)
  - E0032: Phase handler missing
  - E0033: `transition()` outside agent (also: `transition()` in an agent with no Phase enum)
  - E0034: `suspend()` outside agent
  - E0035: `idempotent()` outside handler
  - E0036: `stop()` outside agent

  ### Supervisor (E004x)
  - E0040: Invalid supervisor strategy
  - E0041: Invalid max_restarts value
  - E0042: Supervisor has no children (warning)

  ### Warnings (W000x)
  - W0001: Unused binding
  - W0002: Unused capability
  - W0003: Unreachable code after `stop()`
  - W0004: Enum match covers only specific values of a variant
  """

  alias Skein.AST
  alias Skein.Error

  # Internal type representation
  @type skein_type ::
          :int
          | :float
          | :string
          | :bool
          | :uuid
          | :instant
          | :duration
          | :email
          | :url
          | {:option, skein_type}
          | {:result, skein_type, skein_type}
          | {:list, skein_type}
          | {:map, skein_type, skein_type}
          | {:set, skein_type}
          | {:user_type, String.t()}
          | {:enum, String.t()}
          | :unknown

  # Known effect namespaces and the capabilities they require
  # A nil value means no capability is required (e.g., trace is always available)
  @effect_namespaces %{
    "http" => "http.out",
    "memory" => "memory.kv",
    "llm" => "model",
    "tool" => "tool.use",
    "topic" => "topic.publish",
    "queue" => "queue.publish",
    "trace" => nil,
    "process" => "process.spawn",
    "timer" => "timer",
    "event" => "event.log",
    # Nondeterministic generators are effects, not ambient stdlib (#261):
    # uuid.new() needs `capability uuid`, instant.now() needs `capability instant`.
    # ("clock" is deliberately NOT used — that's the timer/sleep concept.)
    "uuid" => "uuid",
    "instant" => "instant"
  }

  # Known effect methods per namespace
  @effect_methods %{
    "http" => ["get", "post", "put", "patch", "delete"],
    "memory" => ["put", "get", "get!", "delete", "list"],
    "llm" => ["chat", "json", "stream", "embed"],
    "tool" => ["call", "list", "schema"],
    "topic" => ["publish"],
    "queue" => ["publish"],
    "trace" => ["annotate"],
    "process" => ["spawn"],
    "timer" => ["after", "interval", "cancel"],
    "event" => ["log"],
    "uuid" => ["new"],
    "instant" => ["now"]
  }

  # Store operations: store.<table>.<method>(...)
  @store_methods ["get", "get!", "put", "put!", "delete", "query"]

  # Declared return types per effect method (spec §6). Effects return
  # `Result[T, E]`, so a missing `!`/`?` (or `match`) is a *compile* error
  # rather than a runtime crash (skein-testing#1, #260). The error component is
  # kept `:unknown` — it only ever binds in an `Err(e)` arm — while the success
  # component carries the spec's type where doing so is cheap and does not break
  # legitimate field access (e.g. an HTTP response body stays `:unknown`).
  # `llm.json[T]` is resolved from its type parameter, not this table.
  @effect_return_types %{
    {"http", "get"} => {:result, :unknown, :unknown},
    {"http", "post"} => {:result, :unknown, :unknown},
    {"http", "put"} => {:result, :unknown, :unknown},
    {"http", "patch"} => {:result, :unknown, :unknown},
    {"http", "delete"} => {:result, :unknown, :unknown},
    {"memory", "put"} => {:result, :unknown, :unknown},
    {"memory", "get"} => {:result, :unknown, :unknown},
    {"memory", "delete"} => {:result, :string, :unknown},
    {"memory", "list"} => {:list, :string},
    {"llm", "chat"} => {:result, :string, :unknown},
    {"llm", "stream"} => {:result, :string, :unknown},
    {"llm", "embed"} => {:result, {:list, :float}, :unknown},
    {"tool", "call"} => {:result, :unknown, :unknown},
    {"tool", "list"} => {:result, {:list, :unknown}, :unknown},
    {"tool", "schema"} => {:result, :unknown, :unknown},
    {"topic", "publish"} => {:result, :string, :unknown},
    {"queue", "publish"} => {:result, :string, :unknown},
    {"process", "spawn"} => {:result, :unknown, :string},
    {"timer", "after"} => {:result, :string, :string},
    {"timer", "interval"} => {:result, :string, :string},
    {"timer", "cancel"} => {:result, :string, :string},
    # Nondeterministic generators can't fail, so they return the bare value
    # (no Result / no `!` needed) — just like memory.list.
    {"uuid", "new"} => :uuid,
    {"instant", "now"} => :instant
  }

  # store.<table>.<method> return types (spec §6.2). The record type `T` is not
  # tracked per table, so the success side stays `:unknown`; the Result wrapper
  # is what forces `!`/`?`/`match`.
  @store_return_types %{
    "get" => {:result, :unknown, :unknown},
    "put" => {:result, :unknown, :unknown},
    "delete" => {:result, :unknown, :unknown},
    "query" => {:result, {:list, :unknown}, :unknown}
  }

  # Control-flow keywords common in other languages that Skein deliberately
  # does not have. When one appears where an expression is expected it's
  # otherwise mis-reported as an unknown variable; map each to a hint that
  # points at the construct Skein uses instead (skein-testing #5).
  @match_hint "Skein has no '%{kw}'; conditionals are 'match' on Bool, e.g. match cond { true -> ... false -> ... }"
  @absent_keyword_hints %{
    "if" => String.replace(@match_hint, "%{kw}", "if"),
    "else" => String.replace(@match_hint, "%{kw}", "else"),
    "elif" => String.replace(@match_hint, "%{kw}", "elif"),
    "then" => String.replace(@match_hint, "%{kw}", "then"),
    "switch" => String.replace(@match_hint, "%{kw}", "switch"),
    "case" => String.replace(@match_hint, "%{kw}", "case"),
    "cond" => String.replace(@match_hint, "%{kw}", "cond"),
    "unless" => String.replace(@match_hint, "%{kw}", "unless")
  }

  # Standard library function registry: {Module, function} -> {param_types, return_type}
  @stdlib_registry %{
    "String" => %{
      "length" => %{params: [:string], return_type: :int},
      "slice" => %{params: [:string, :int, :int], return_type: :string},
      "contains" => %{params: [:string, :string], return_type: :bool},
      "split" => %{params: [:string, :string], return_type: {:list, :string}},
      "trim" => %{params: [:string], return_type: :string},
      "upcase" => %{params: [:string], return_type: :string},
      "downcase" => %{params: [:string], return_type: :string},
      "starts_with" => %{params: [:string, :string], return_type: :bool},
      "ends_with" => %{params: [:string, :string], return_type: :bool},
      "replace" => %{params: [:string, :string, :string], return_type: :string}
    },
    "Int" => %{
      "parse" => %{params: [:string], return_type: {:result, :int, :string}},
      "to_string" => %{params: [:int], return_type: :string},
      "abs" => %{params: [:int], return_type: :int},
      "min" => %{params: [:int, :int], return_type: :int},
      "max" => %{params: [:int, :int], return_type: :int},
      "clamp" => %{params: [:int, :int, :int], return_type: :int}
    },
    "Float" => %{
      "parse" => %{params: [:string], return_type: {:result, :float, :string}},
      "to_string" => %{params: [:float], return_type: :string},
      "round" => %{params: [:float, :int], return_type: :float},
      "ceil" => %{params: [:float], return_type: :int},
      "floor" => %{params: [:float], return_type: :int}
    },
    "List" => %{
      "length" => %{params: [{:list, :unknown}], return_type: :int},
      "map" => %{params: [{:list, :unknown}, :unknown], return_type: {:list, :unknown}},
      "filter" => %{params: [{:list, :unknown}, :unknown], return_type: {:list, :unknown}},
      "reduce" => %{params: [{:list, :unknown}, :unknown, :unknown], return_type: :unknown},
      "find" => %{params: [{:list, :unknown}, :unknown], return_type: {:option, :unknown}},
      "first" => %{params: [{:list, :unknown}], return_type: {:option, :unknown}},
      "last" => %{params: [{:list, :unknown}], return_type: {:option, :unknown}},
      "head" => %{params: [{:list, :unknown}], return_type: {:option, :unknown}},
      "tail" => %{params: [{:list, :unknown}], return_type: {:list, :unknown}},
      "take" => %{params: [{:list, :unknown}, :int], return_type: {:list, :unknown}},
      "drop" => %{params: [{:list, :unknown}, :int], return_type: {:list, :unknown}},
      "sort" => %{params: [{:list, :unknown}], return_type: {:list, :unknown}},
      "sort_by" => %{params: [{:list, :unknown}, :unknown], return_type: {:list, :unknown}},
      "reverse" => %{params: [{:list, :unknown}], return_type: {:list, :unknown}},
      "flatten" => %{params: [{:list, :unknown}], return_type: {:list, :unknown}},
      "concat" => %{
        params: [{:list, :unknown}, {:list, :unknown}],
        return_type: {:list, :unknown}
      },
      "contains" => %{params: [{:list, :unknown}, :unknown], return_type: :bool},
      "any" => %{params: [{:list, :unknown}, :unknown], return_type: :bool},
      "all" => %{params: [{:list, :unknown}, :unknown], return_type: :bool},
      "none" => %{params: [{:list, :unknown}, :unknown], return_type: :bool},
      "zip" => %{params: [{:list, :unknown}, {:list, :unknown}], return_type: {:list, :unknown}},
      "uniq" => %{params: [{:list, :unknown}], return_type: {:list, :unknown}},
      "count" => %{params: [{:list, :unknown}, :unknown], return_type: :int},
      "group_by" => %{
        params: [{:list, :unknown}, :unknown],
        return_type: {:map, :unknown, {:list, :unknown}}
      }
    },
    "Map" => %{
      "get" => %{params: [{:map, :unknown, :unknown}, :unknown], return_type: {:option, :unknown}},
      "put" => %{
        params: [{:map, :unknown, :unknown}, :unknown, :unknown],
        return_type: {:map, :unknown, :unknown}
      },
      "delete" => %{
        params: [{:map, :unknown, :unknown}, :unknown],
        return_type: {:map, :unknown, :unknown}
      },
      "keys" => %{params: [{:map, :unknown, :unknown}], return_type: {:list, :unknown}},
      "values" => %{params: [{:map, :unknown, :unknown}], return_type: {:list, :unknown}},
      "entries" => %{params: [{:map, :unknown, :unknown}], return_type: {:list, :unknown}},
      "size" => %{params: [{:map, :unknown, :unknown}], return_type: :int},
      "has" => %{params: [{:map, :unknown, :unknown}, :unknown], return_type: :bool},
      "merge" => %{
        params: [{:map, :unknown, :unknown}, {:map, :unknown, :unknown}],
        return_type: {:map, :unknown, :unknown}
      },
      "map_values" => %{
        params: [{:map, :unknown, :unknown}, :unknown],
        return_type: {:map, :unknown, :unknown}
      },
      "filter" => %{
        params: [{:map, :unknown, :unknown}, :unknown],
        return_type: {:map, :unknown, :unknown}
      }
    },
    "Set" => %{
      "from" => %{params: [{:list, :unknown}], return_type: {:set, :unknown}},
      "add" => %{params: [{:set, :unknown}, :unknown], return_type: {:set, :unknown}},
      "remove" => %{params: [{:set, :unknown}, :unknown], return_type: {:set, :unknown}},
      "contains" => %{params: [{:set, :unknown}, :unknown], return_type: :bool},
      "size" => %{params: [{:set, :unknown}], return_type: :int},
      "union" => %{params: [{:set, :unknown}, {:set, :unknown}], return_type: {:set, :unknown}},
      "intersection" => %{
        params: [{:set, :unknown}, {:set, :unknown}],
        return_type: {:set, :unknown}
      },
      "difference" => %{
        params: [{:set, :unknown}, {:set, :unknown}],
        return_type: {:set, :unknown}
      },
      "to_list" => %{params: [{:set, :unknown}], return_type: {:list, :unknown}}
    },
    "Option" => %{
      "unwrap" => %{params: [{:option, :unknown}, :unknown], return_type: :unknown},
      "map" => %{params: [{:option, :unknown}, :unknown], return_type: {:option, :unknown}},
      "flat_map" => %{params: [{:option, :unknown}, :unknown], return_type: {:option, :unknown}},
      "is_some" => %{params: [{:option, :unknown}], return_type: :bool},
      "is_none" => %{params: [{:option, :unknown}], return_type: :bool}
    },
    "Result" => %{
      "unwrap" => %{params: [{:result, :unknown, :unknown}, :unknown], return_type: :unknown},
      "map" => %{
        params: [{:result, :unknown, :unknown}, :unknown],
        return_type: {:result, :unknown, :unknown}
      },
      "map_err" => %{
        params: [{:result, :unknown, :unknown}, :unknown],
        return_type: {:result, :unknown, :unknown}
      },
      "flat_map" => %{
        params: [{:result, :unknown, :unknown}, :unknown],
        return_type: {:result, :unknown, :unknown}
      },
      "is_ok" => %{params: [{:result, :unknown, :unknown}], return_type: :bool},
      "is_err" => %{params: [{:result, :unknown, :unknown}], return_type: :bool},
      "ok" => %{params: [:unknown], return_type: {:result, :unknown, :unknown}},
      "err" => %{params: [:unknown], return_type: {:result, :unknown, :unknown}}
    },
    "Uuid" => %{
      # `new` is an effect now (uuid.new(), #261), not ambient stdlib.
      "parse" => %{params: [:string], return_type: {:result, :uuid, :string}},
      "to_string" => %{params: [:uuid], return_type: :string}
    },
    "Instant" => %{
      # `now` is an effect now (instant.now(), #261), not ambient stdlib.
      "parse" => %{params: [:string], return_type: {:result, :instant, :string}},
      "to_string" => %{params: [:instant], return_type: :string},
      "add" => %{params: [:instant, :duration], return_type: :instant},
      "subtract" => %{params: [:instant, :duration], return_type: :instant},
      "diff" => %{params: [:instant, :instant], return_type: :duration},
      "is_before" => %{params: [:instant, :instant], return_type: :bool},
      "is_after" => %{params: [:instant, :instant], return_type: :bool}
    },
    "Duration" => %{
      "seconds" => %{params: [:int], return_type: :duration},
      "minutes" => %{params: [:int], return_type: :duration},
      "hours" => %{params: [:int], return_type: :duration},
      "days" => %{params: [:int], return_type: :duration},
      "to_seconds" => %{params: [:duration], return_type: :int},
      "to_string" => %{params: [:duration], return_type: :string}
    }
  }

  @stdlib_modules Map.keys(@stdlib_registry)

  # Environment tracks types, functions, variables, and capabilities in scope
  @type env :: %{
          module_name: String.t() | nil,
          types: %{String.t() => :builtin | AST.TypeDecl.t()},
          enums: %{String.t() => AST.EnumDecl.t()},
          functions: %{String.t() => %{params: [AST.Field.t()], return_type: skein_type}},
          variables: %{String.t() => skein_type},
          capabilities: [AST.Capability.t()],
          tool_error_names: [String.t()],
          current_fn_return_type: skein_type | nil,
          file: String.t()
        }

  @builtin_types %{
    "Int" => :int,
    "Float" => :float,
    "String" => :string,
    "Bool" => :bool,
    "Uuid" => :uuid,
    "Instant" => :instant,
    "Duration" => :duration,
    "Email" => :email,
    "Url" => :url
  }

  # Effect error/response types defined by the Effects API (spec section 6).
  # They are part of the language surface — Result[T, HttpError] in a fn
  # signature must not be an unknown-type error.
  @effect_type_names ~w(
    HttpResponse HttpError StoreError NotFound MemoryError LlmError
    ToolError ToolInfo ToolName PublishError
  )

  @builtin_type_names Map.keys(@builtin_types) ++ @effect_type_names

  @spec analyze(AST.Module.t() | AST.Agent.t(), keyword()) ::
          {:ok, AST.Module.t() | AST.Agent.t()} | {:error, [Error.t()]}
  def analyze(ast, opts \\ [])

  def analyze(%AST.Module{} = ast, opts) do
    env = build_initial_env(ast) |> put_source_text(opts)

    # Pass 0a: Resolve named arguments into positional order (desugaring).
    # Later passes and codegen only ever see positional arguments.
    {ast, errors} = resolve_named_args(ast, env)

    nested_agents = Enum.filter(ast.declarations, &match?(%AST.Agent{}, &1))

    # Fn-shaped views of nested agent bodies, so module-level usage passes
    # (unused capabilities) see effects exercised inside nested agents.
    nested_agent_views = Enum.flat_map(nested_agents, &agent_decl_views/1)

    # Fn-shaped views of test/scenario/golden bodies: effect calls inside
    # test blocks need capabilities (E0012) and count as capability usage
    # (no W0002 false positives on the skein new scaffold) — issue #104.
    test_views = test_decl_views(ast.declarations)

    # Pass 0: Check for duplicate definitions
    errors = errors ++ check_duplicate_definitions(ast.declarations, env)

    # Pass 1: Validate type and enum declarations
    errors = errors ++ validate_declarations(ast.declarations, env)

    # Pass 2: Type-check function bodies
    errors = errors ++ check_functions(ast.declarations, env)

    # Pass 2b: Type-check handler bodies
    errors = errors ++ check_handlers(ast.declarations, env)

    # Pass 2d: Type-check test / scenario / golden bodies (#253)
    errors = errors ++ check_test_inference(ast.declarations, env)

    # Pass 2e: Type-check tool `implement` bodies (#253)
    errors = errors ++ check_tool_implement_inference(ast.declarations, env)

    # Pass 2c: Scope-independent interpolation rules — uppercase
    # interpolation roots and interpolated string patterns. One generic
    # walk covers bodies the type-inference passes skip (test blocks).
    errors = errors ++ check_interpolation_shapes(ast.declarations ++ test_views, env)

    # Pass 3: Capability checking — verify effect calls have covering
    # capabilities (test/scenario/golden bodies included)
    errors = errors ++ check_capabilities(ast.declarations ++ test_views, env)

    # Pass 4: Unused binding warnings
    errors = errors ++ check_unused_bindings_in_declarations(ast.declarations, env)

    # Pass 5: Unused capability warnings (nested agent and test-block
    # usage counts)
    errors =
      errors ++
        check_unused_capabilities(ast.declarations ++ nested_agent_views ++ test_views, env)

    # Pass 6: Unreachable code after stop() warnings
    errors = errors ++ check_unreachable_after_stop(ast.declarations)

    # Pass 7: agent-only lifecycle calls (transition/suspend/stop) outside
    # agent handlers — test/scenario/golden bodies included, so codegen
    # never sees these nodes on the module path
    errors = errors ++ check_agent_only_calls(ast.declarations ++ test_views, env)

    # Pass 8: idempotent() outside handler check
    errors = errors ++ check_idempotent_outside_handler(ast.declarations, env)

    # Pass 9: Nested agents — run the full agent pass suite with the
    # module's types, enums, and capabilities in scope
    errors =
      errors ++
        Enum.flat_map(nested_agents, fn agent ->
          run_agent_passes(agent, build_nested_agent_env(agent, env))
        end)

    # Pass 10: schema-bearing type params on `*.json[T]` calls (nested-agent
    # bodies are covered by Pass 9 above, so exclude them here to avoid
    # duplicate diagnostics)
    non_agent_decls = Enum.reject(ast.declarations, &match?(%AST.Agent{}, &1))
    errors = errors ++ check_schema_type_params(non_agent_decls ++ test_views, env)

    filter_result(errors, ast, env)
  end

  def analyze(%AST.Agent{} = ast, opts) do
    env = build_agent_env(ast) |> put_source_text(opts)

    # Pass 0a: Resolve named arguments into positional order (desugaring).
    {ast, errors} = resolve_named_args(ast, env)

    errors = errors ++ run_agent_passes(ast, env)

    filter_result(errors, ast, env)
  end

  # All agent-specific analysis passes. Used both for top-level agents
  # and for agents nested inside modules (with a module-enriched env).
  defp run_agent_passes(%AST.Agent{} = ast, env) do
    # Pass 1: Validate state field types
    errors = validate_agent_state(ast.state, env)

    # Pass 2: Validate phase transitions
    errors = errors ++ validate_phase_transitions(ast, env)

    # Pass 3: Check that all reachable phases have handlers
    errors = errors ++ check_phase_handlers(ast, env)

    # Pass 4: Validate transition() calls match declared transitions
    errors = errors ++ validate_transition_calls(ast, env)

    # Pass 5: Type-check agent function bodies
    errors = errors ++ check_functions(ast.fns, env)

    # Pass 5b: Full type inference on agent handler bodies (#253). Handler
    # bodies are executable — they bind effect results, drive transitions, and
    # build emitted events. Running the same inference the rest of the pipeline
    # uses (with the handler's params in scope on top of the agent's state and
    # functions) makes a missing `!`/`?`, an over/under-applied effect, or any
    # other type error a compile error instead of a runtime crash. This
    # subsumes the older arity-only walk.
    errors = errors ++ check_agent_handler_inference(ast, env)

    all_decls = agent_decl_views(ast)

    # Pass 5c: Scope-independent interpolation rules (uppercase roots,
    # interpolated string patterns) — handler bodies skip infer_type, so
    # this walk is what rejects "${Foo}" inside them.
    errors = errors ++ check_interpolation_shapes(all_decls, env)

    # Pass 6: Unreachable code after stop() warnings
    errors = errors ++ check_unreachable_after_stop(all_decls)

    # Pass 7: Capability checking — verify effect calls have covering capabilities
    errors = errors ++ check_capabilities(all_decls, env)

    # Pass 8: Unused capability warnings — only the agent's OWN capability
    # declarations are candidates (a nested agent's env also carries the
    # enclosing module's capabilities for coverage checking; their usage
    # is accounted for at module level)
    own_caps_env = %{env | capabilities: Map.get(env, :own_capabilities, env.capabilities)}
    errors = errors ++ check_unused_capabilities(all_decls, own_caps_env)

    # Schema-bearing type params on `*.json[T]` calls in agent bodies
    errors = errors ++ check_schema_type_params(all_decls, env)

    # idempotent() in agent fns (not handlers) is invalid
    errors ++ check_idempotent_in_agent_fns(ast.fns, env)
  end

  # Fn-shaped views of test/scenario/golden bodies, for reuse with the
  # declaration-driven capability passes.
  defp test_decl_views(declarations) do
    Enum.flat_map(declarations, fn
      %AST.Test{body: body, meta: meta} ->
        [%AST.Fn{name: "__test__", params: [], return_type: nil, body: body, meta: meta}]

      %AST.Scenario{expect_body: body, meta: meta} ->
        [%AST.Fn{name: "__scenario__", params: [], return_type: nil, body: body, meta: meta}]

      %AST.Golden{body: body, meta: meta} ->
        [%AST.Fn{name: "__golden__", params: [], return_type: nil, body: body, meta: meta}]

      _ ->
        []
    end)
  end

  # Fn-shaped views of an agent's fns and handler bodies, for reuse with
  # the declaration-driven passes (capabilities, unreachable code, ...).
  defp agent_decl_views(%AST.Agent{} = ast) do
    handler_decls =
      Enum.map(ast.handlers, fn h ->
        %AST.Fn{name: "__handler__", params: [], return_type: nil, body: h.body, meta: h.meta}
      end)

    ast.fns ++ handler_decls
  end

  defp put_source_text(env, opts) do
    case Keyword.get(opts, :source_text) do
      nil -> Map.put(env, :source_lines, nil)
      text -> Map.put(env, :source_lines, String.split(text, "\n"))
    end
  end

  defp enrich_error_context(%Error{location: %{line: line}} = error, source_lines)
       when is_list(source_lines) and line > 0 and line <= length(source_lines) do
    context_line = Enum.at(source_lines, line - 1)
    %{error | context: String.trim(context_line)}
  end

  defp enrich_error_context(error, _source_lines), do: error

  defp enrich_errors(errors, %{source_lines: nil}), do: errors

  defp enrich_errors(errors, %{source_lines: source_lines}) do
    Enum.map(errors, fn error ->
      error
      |> enrich_error_context(source_lines)
      |> enrich_fix_code()
    end)
  end

  defp enrich_errors(errors, _env), do: errors

  defp enrich_fix_code(%Error{code: "E0020", fix_code: nil} = error) do
    %{error | fix_code: extract_type_mismatch_fix(error.message)}
  end

  defp enrich_fix_code(error), do: error

  defp extract_type_mismatch_fix(message) do
    case Regex.run(~r/expected (\w+)/i, message) do
      [_, expected_type] -> "// Change expression type to #{expected_type}"
      _ -> "// Fix the type mismatch"
    end
  end

  defp filter_result(errors, ast, env) do
    errors = enrich_errors(errors, env)
    hard_errors = Enum.filter(errors, &(&1.severity == :error))
    warnings = Enum.filter(errors, &(&1.severity == :warning))

    case hard_errors do
      [] when warnings == [] ->
        {:ok, ast}

      [] ->
        # Only warnings — compilation succeeds, but report warnings
        {:ok, ast, warnings}

      _ ->
        {:error, errors}
    end
  end

  # ------------------------------------------------------------------
  # Named argument resolution (Pass 0a)
  #
  # Calls may pass arguments by name (`f(b: 2, a: 1)`), with named
  # arguments allowed only after positional ones. This pass validates
  # named arguments against the callee's parameter names and rewrites
  # every call into positional order, so all later passes — and
  # codegen — only ever see positional arguments. Violations are E0026.
  # ------------------------------------------------------------------

  # Parameter names for effect calls, aligned with the Effects API
  # signatures in SKEIN_SPEC.md section 6. Effects not listed here
  # (tool.*, timer.*) do not support named arguments.
  @effect_param_names %{
    {"http", "get"} => ["url"],
    {"http", "post"} => ["url", "json"],
    {"http", "put"} => ["url", "json"],
    {"http", "patch"} => ["url", "json"],
    {"http", "delete"} => ["url"],
    {"memory", "put"} => ["key", "value"],
    {"memory", "get"} => ["key"],
    {"memory", "get!"} => ["key"],
    {"memory", "delete"} => ["key"],
    {"memory", "list"} => ["prefix"],
    {"llm", "chat"} => ["model", "system", "input"],
    {"llm", "json"} => ["model", "system", "input"],
    {"llm", "stream"} => ["model", "system", "input", "on_chunk"],
    {"llm", "embed"} => ["model", "input"],
    {"topic", "publish"} => ["name", "data"],
    {"queue", "publish"} => ["name", "data"],
    {"trace", "annotate"} => ["key", "value"],
    {"process", "spawn"} => ["task", "work"],
    {"event", "log"} => ["name", "data"],
    {"timer", "after"} => ["delay_ms", "task", "work"],
    {"timer", "interval"} => ["every_ms", "task", "work"],
    {"timer", "cancel"} => ["ref"],
    {"uuid", "new"} => [],
    {"instant", "now"} => []
  }

  # Trailing effect parameters that may be omitted. `process.spawn(name)`
  # spawns a named no-op; the optional `work` fn reference attaches a task
  # body (spec §6.11). Only trailing parameters can be optional — omitting
  # a middle parameter would shift the positional order.
  @effect_optional_params %{
    {"llm", "stream"} => ["on_chunk"],
    {"process", "spawn"} => ["work"],
    {"timer", "after"} => ["work"],
    {"timer", "interval"} => ["work"]
  }

  defp resolve_named_args(%AST.Call{} = call, env) do
    {target, target_errors} = resolve_named_args(call.target, env)
    {args, arg_errors} = resolve_named_args(call.args, env)
    {call, call_errors} = resolve_call_named_args(%{call | target: target, args: args}, env)
    {call, target_errors ++ arg_errors ++ call_errors}
  end

  defp resolve_named_args(%AST.NamedArg{value: value} = named, env) do
    {value, errors} = resolve_named_args(value, env)
    {%{named | value: value}, errors}
  end

  # Inside an agent, calls resolve against the agent's own fns —
  # swap the callable set before walking the agent's body.
  defp resolve_named_args(%AST.Agent{fns: fns} = agent, env) do
    functions =
      Map.new(fns, fn %AST.Fn{name: name, params: params} ->
        {name, %{params: params, return_type: :unknown}}
      end)

    resolve_named_args_fields(agent, %{env | functions: functions})
  end

  defp resolve_named_args(%_{} = node, env) do
    resolve_named_args_fields(node, env)
  end

  defp resolve_named_args(nodes, env) when is_list(nodes) do
    Enum.map_reduce(nodes, [], fn node, errors_acc ->
      {node, errors} = resolve_named_args(node, env)
      {node, errors_acc ++ errors}
    end)
  end

  # String interpolation segments ({:interpolation, expr}) and map
  # literal entries ({key, expr}) carry expressions in their second slot.
  defp resolve_named_args({tag, value}, env) do
    {value, errors} = resolve_named_args(value, env)
    {{tag, value}, errors}
  end

  defp resolve_named_args(other, _env), do: {other, []}

  defp resolve_named_args_fields(%_{} = node, env) do
    node
    |> Map.from_struct()
    |> Enum.reduce({node, []}, fn
      {:meta, _value}, acc ->
        acc

      {key, value}, {node_acc, errors_acc} ->
        {value, errors} = resolve_named_args(value, env)
        {Map.put(node_acc, key, value), errors_acc ++ errors}
    end)
  end

  defp resolve_call_named_args(%AST.Call{args: args} = call, env) do
    if Enum.any?(args, &match?(%AST.NamedArg{}, &1)) do
      reorder_named_args(call, env)
    else
      {call, []}
    end
  end

  defp reorder_named_args(%AST.Call{args: args, meta: meta} = call, env) do
    {positional, named_section} = Enum.split_while(args, &(not match?(%AST.NamedArg{}, &1)))

    case Enum.find(named_section, &(not match?(%AST.NamedArg{}, &1))) do
      nil ->
        case callee_param_names(call, env) do
          {:ok, callee, param_names, optional_names} ->
            apply_named_args(
              call,
              positional,
              named_section,
              callee,
              param_names,
              optional_names,
              env
            )

          :unsupported ->
            error = %Error{
              code: "E0026",
              severity: :error,
              message: "Named arguments are not supported for #{describe_callee(call.target)}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Use positional arguments"
            }

            {strip_named_args(call), [error]}
        end

      stray ->
        error = %Error{
          code: "E0026",
          severity: :error,
          message: "Positional argument after named argument",
          location: location_from_meta(Map.get(stray, :meta) || meta, env.file),
          fix_hint: "Move positional arguments before all named arguments"
        }

        {strip_named_args(call), [error]}
    end
  end

  defp apply_named_args(call, positional, named, callee, param_names, optional_names, env) do
    filled_positionally = Enum.take(param_names, length(positional))
    remaining = Enum.drop(param_names, length(positional))

    name_errors =
      duplicate_named_arg_errors(named, callee, env) ++
        Enum.flat_map(named, fn %AST.NamedArg{name: name, meta: meta} ->
          cond do
            name in remaining ->
              []

            name in filled_positionally ->
              [
                %Error{
                  code: "E0026",
                  severity: :error,
                  message:
                    "Argument '#{name}' in call to #{callee} is already provided positionally",
                  location: location_from_meta(meta, env.file),
                  fix_hint: "Remove the named argument or pass '#{name}' only positionally"
                }
              ]

            true ->
              [
                %Error{
                  code: "E0026",
                  severity: :error,
                  message: "Unknown argument '#{name}' in call to #{callee}",
                  location: location_from_meta(meta, env.file),
                  fix_hint: "Valid argument names: #{Enum.join(param_names, ", ")}",
                  fix_code: "#{closest_name(name, param_names)}:"
                }
              ]
          end
        end)

    named_by_name = Map.new(named, fn %AST.NamedArg{name: name} = arg -> {name, arg} end)

    missing =
      Enum.reject(remaining, fn name ->
        Map.has_key?(named_by_name, name) or name in optional_names
      end)

    missing_errors =
      if name_errors == [] and missing != [] do
        names = Enum.map_join(missing, ", ", &"'#{&1}'")

        [
          %Error{
            code: "E0026",
            severity: :error,
            message: "Missing argument(s) #{names} in call to #{callee}",
            location: location_from_meta(call.meta, env.file),
            fix_hint: "Pass #{names} positionally or by name"
          }
        ]
      else
        []
      end

    case name_errors ++ missing_errors do
      [] ->
        # Omitted trailing optional params simply drop out of the call
        ordered_named =
          remaining
          |> Enum.filter(&Map.has_key?(named_by_name, &1))
          |> Enum.map(fn name -> Map.fetch!(named_by_name, name).value end)

        {%{call | args: positional ++ ordered_named}, []}

      errors ->
        {strip_named_args(call), errors}
    end
  end

  defp duplicate_named_arg_errors(named, callee, env) do
    named
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, args} -> length(args) > 1 end)
    |> Enum.sort_by(fn {name, _args} -> name end)
    |> Enum.map(fn {name, [_first | [dup | _]]} ->
      %Error{
        code: "E0026",
        severity: :error,
        message: "Duplicate named argument '#{name}' in call to #{callee}",
        location: location_from_meta(dup.meta, env.file),
        fix_hint: "Pass '#{name}' only once"
      }
    end)
  end

  defp callee_param_names(%AST.Call{target: %AST.Identifier{name: name}}, env) do
    case Map.fetch(env.functions, name) do
      {:ok, fn_info} -> {:ok, "'#{name}'", Enum.map(fn_info.params, & &1.name), []}
      :error -> :unsupported
    end
  end

  defp callee_param_names(
         %AST.Call{
           target: %AST.FieldAccess{subject: %AST.Identifier{name: namespace}, field: method}
         },
         _env
       ) do
    case Map.fetch(@effect_param_names, {namespace, method}) do
      {:ok, names} ->
        optional = Map.get(@effect_optional_params, {namespace, method}, [])
        {:ok, "'#{namespace}.#{method}'", names, optional}

      :error ->
        :unsupported
    end
  end

  defp callee_param_names(_call, _env), do: :unsupported

  # Positional-arity bounds for documented effect signatures. Codegen
  # appends trailing runtime arguments (callbacks, scope labels, the
  # capability list) to effect calls, so over- or under-application in
  # source would otherwise silently compile to a call on a nonexistent
  # runtime arity. Effects without a param-table entry (tool.*, store.*)
  # have their own checks and are skipped here.
  # The declared return type of an effect call (spec §6). `llm.json[T]` reads
  # its success type from the type parameter; everything else comes from the
  # static table. Unmapped-but-known methods (e.g. the `!` forms, `memory.get!`)
  # fall back to `:unknown`.
  defp effect_call_return_type("llm", "json", %AST.TypeRef{} = type_param, env) do
    {:result, resolve_type(type_param, env.types), :unknown}
  end

  defp effect_call_return_type(namespace, method, _type_param, _env) do
    Map.get(@effect_return_types, {namespace, method}, :unknown)
  end

  defp unknown_effect_method_error(namespace, method, meta, env) do
    known = Map.get(@effect_methods, namespace, [])

    %Error{
      code: "E0010",
      severity: :error,
      message: "Unknown effect method '#{namespace}.#{method}'",
      location: location_from_meta(meta, env.file),
      context: "'#{namespace}' has no '#{method}' method",
      fix_hint: "Available methods: #{Enum.join(known, ", ")}",
      fix_code: "#{namespace}.#{closest_name(method, known)}"
    }
  end

  defp effect_call_arity_errors(namespace, method, args, meta, env) do
    case Map.fetch(@effect_param_names, {namespace, method}) do
      {:ok, names} ->
        optional = Map.get(@effect_optional_params, {namespace, method}, [])
        min_arity = length(names) - length(optional)
        max_arity = length(names)
        actual = length(args)

        if actual < min_arity or actual > max_arity do
          expected =
            if min_arity == max_arity,
              do: "#{max_arity}",
              else: "#{min_arity} to #{max_arity}"

          [
            %Error{
              code: "E0020",
              severity: :error,
              message:
                "Effect '#{namespace}.#{method}' expects #{expected} argument(s) (#{Enum.join(names, ", ")}), got #{actual}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Pass #{expected} argument(s) to '#{namespace}.#{method}'",
              fix_code: call_skeleton("#{namespace}.#{method}", max_arity)
            }
          ]
        else
          []
        end

      :error ->
        []
    end
  end

  # Full type inference over every agent handler body (#253). Each handler's
  # declared params (e.g. `on start(order_id: String)`) are bound on top of the
  # agent env (which already carries state fields, functions, types, and enums),
  # then the body is inferred like any other executable body — catching missing
  # `!`/`?`, effect arity, and type mismatches that the body would otherwise
  # only surface as a runtime crash.
  defp check_agent_handler_inference(%AST.Agent{handlers: handlers}, env) do
    Enum.flat_map(handlers, fn %AST.AgentHandler{params: params, body: body} ->
      param_vars =
        (params || [])
        |> Enum.map(fn %AST.Field{name: name, type: type} ->
          {name, resolve_type(type, env.types)}
        end)
        |> Map.new()

      # `state` is the runtime-provided instance state map; field access on it
      # (`state.ticket_id`) stays permissive (:unknown) — it is the gen_statem
      # data, not a compile-time-typed record.
      variables =
        env.variables
        |> Map.put("state", :unknown)
        |> Map.merge(param_vars)

      handler_env = %{env | variables: variables}
      {_type, errors} = infer_type(body, handler_env)
      errors
    end)
  end

  # ------------------------------------------------------------------
  # Interpolation shape checking
  # ------------------------------------------------------------------

  # Structural interpolation rules that hold regardless of scope, checked
  # by one generic walk over every declaration body (module fns, handlers,
  # tools, test blocks, agent fns, agent handlers):
  #
  #   * interpolation roots must be lowercase references — "${Foo}" would
  #     otherwise compile to a bare variant atom (or crash codegen)
  #   * string patterns must be literal — an interpolated pattern has no
  #     match-time value (codegen lowers string patterns byte-by-byte)
  #
  # Scope checking of lowercase references stays in check_interpolation
  # (it needs the binding environment that only type inference tracks).
  defp check_interpolation_shapes(declarations, env) do
    declarations
    |> Enum.flat_map(&interpolation_shape_errors(&1, env))
  end

  defp interpolation_shape_errors(%AST.StringLit{segments: segments}, env) do
    segments
    |> Enum.flat_map(fn
      {:interpolation, expr} -> uppercase_interpolation_errors(expr, env)
      _literal -> []
    end)
  end

  defp interpolation_shape_errors(
         %AST.MatchArm{pattern: pattern, guard: guard, body: body},
         env
       ) do
    pattern_interpolation_errors(pattern, env) ++
      interpolation_shape_errors(guard, env) ++ interpolation_shape_errors(body, env)
  end

  # Nested agents run the full agent pass suite (which includes this
  # check), so the module-level walk must not descend into them.
  defp interpolation_shape_errors(%AST.Agent{}, _env), do: []

  defp interpolation_shape_errors(%_{} = node, env) do
    node
    |> Map.from_struct()
    |> Enum.flat_map(fn
      {:meta, _} -> []
      {_key, value} -> interpolation_shape_errors(value, env)
    end)
  end

  defp interpolation_shape_errors(nodes, env) when is_list(nodes),
    do: Enum.flat_map(nodes, &interpolation_shape_errors(&1, env))

  defp interpolation_shape_errors({_tag, value}, env), do: interpolation_shape_errors(value, env)
  defp interpolation_shape_errors(_other, _env), do: []

  defp uppercase_interpolation_errors(%AST.Identifier{name: name, meta: meta}, env) do
    if String.match?(name, ~r/^[A-Z]/) do
      [
        %Error{
          code: "E0010",
          severity: :error,
          message:
            "Cannot interpolate '#{name}': string interpolation accepts let bindings, parameters, and field access on them",
          location: location_from_meta(meta, env.file),
          fix_hint: "Bind the value to a lowercase name first, then interpolate that binding",
          fix_code: "let value = #{name}"
        }
      ]
    else
      []
    end
  end

  defp uppercase_interpolation_errors(%AST.FieldAccess{subject: subject}, env),
    do: uppercase_interpolation_errors(subject, env)

  defp uppercase_interpolation_errors(_other, _env), do: []

  # Patterns reject ALL interpolation (uppercase or not), so the walk above
  # skips MatchArm patterns and this check reports them once.
  defp pattern_interpolation_errors(%AST.StringLit{segments: segments, meta: meta}, env) do
    if Enum.all?(segments, &match?({:literal, _}, &1)) do
      []
    else
      [
        %Error{
          code: "E0020",
          severity: :error,
          message: "String patterns cannot contain interpolation",
          location: location_from_meta(meta, env.file),
          fix_hint:
            "Match on a binding instead, or compare against the interpolated string with == in a guard",
          fix_code: nil
        }
      ]
    end
  end

  defp pattern_interpolation_errors(%AST.Call{args: args}, env),
    do: Enum.flat_map(args, &pattern_interpolation_errors(&1, env))

  defp pattern_interpolation_errors(_other, _env), do: []

  # Generic expression walker collecting every Call node (including calls
  # nested in arguments, match arms, interpolations, and map literals).
  defp collect_calls(%AST.Call{target: target, args: args} = call) do
    [call | Enum.flat_map([target | args], &collect_calls/1)]
  end

  defp collect_calls(%_{} = node) do
    node
    |> Map.from_struct()
    |> Enum.flat_map(fn
      {:meta, _} -> []
      {_key, value} -> collect_calls(value)
    end)
  end

  defp collect_calls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_calls/1)
  defp collect_calls({_tag, value}), do: collect_calls(value)
  defp collect_calls(_other), do: []

  # Validates schema-bearing type parameters on `*.json[T]` calls (`req.json[T]`,
  # `llm.json[T]`, `msg.json[T]`) across every body — including tool `implement`
  # blocks that the per-body inference passes do not yet visit. An undeclared T
  # is never otherwise caught, yet reaches codegen, where it silently emits an
  # empty JSON Schema on a public boundary. :unknown is transient-only: pin the
  # type to a declared one before codegen (issue #259, criterion 4).
  defp check_schema_type_params(declarations, env) do
    declarations
    |> collect_calls()
    |> Enum.flat_map(fn
      %AST.Call{type_param: %AST.TypeRef{} = type_ref} -> validate_type_ref(type_ref, env)
      _ -> []
    end)
  end

  defp describe_callee(%AST.Identifier{name: name}), do: "'#{name}'"

  defp describe_callee(%AST.FieldAccess{subject: %AST.Identifier{name: subject}, field: field}),
    do: "'#{subject}.#{field}'"

  defp describe_callee(_target), do: "this call"

  defp strip_named_args(%AST.Call{args: args} = call) do
    %{
      call
      | args:
          Enum.map(args, fn
            %AST.NamedArg{value: value} -> value
            arg -> arg
          end)
    }
  end

  # ------------------------------------------------------------------
  # Environment construction
  # ------------------------------------------------------------------

  defp build_initial_env(%AST.Module{name: module_name, declarations: declarations, meta: meta}) do
    file = Map.get(meta, :file, "unknown")

    # Register all built-in types
    types =
      Map.new(@builtin_type_names, fn name -> {name, :builtin} end)

    # Register parameterized built-in types
    types =
      types
      |> Map.put("Option", :builtin_param)
      |> Map.put("Result", :builtin_param)
      |> Map.put("List", :builtin_param)
      |> Map.put("Map", :builtin_param)
      |> Map.put("Set", :builtin_param)

    # Register user-declared types
    types =
      Enum.reduce(declarations, types, fn
        %AST.TypeDecl{name: name} = decl, acc -> Map.put(acc, name, decl)
        _, acc -> acc
      end)

    # Register user-declared enums
    enums =
      declarations
      |> Enum.filter(&match?(%AST.EnumDecl{}, &1))
      |> Map.new(fn %AST.EnumDecl{name: name} = decl -> {name, decl} end)

    # Register enums as types too
    types =
      Enum.reduce(enums, types, fn {name, _}, acc -> Map.put(acc, name, :enum) end)

    # Register functions
    functions =
      declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Map.new(fn %AST.Fn{name: name, params: params, return_type: ret} ->
        {name, %{params: params, return_type: resolve_type(ret, types)}}
      end)

    # Extract capabilities
    capabilities =
      declarations
      |> Enum.filter(&match?(%AST.Capability{}, &1))

    # Error type names declared in tool `errors { ... }` blocks — these are
    # referenced as `ErrorName.from(e)` and are not module references
    tool_error_names =
      declarations
      |> Enum.filter(&match?(%AST.ToolDecl{}, &1))
      |> Enum.flat_map(& &1.errors)

    %{
      module_name: module_name,
      types: types,
      enums: enums,
      functions: functions,
      variables: %{},
      capabilities: capabilities,
      tool_error_names: tool_error_names,
      current_fn_return_type: nil,
      file: file,
      decl_meta: meta
    }
  end

  # ------------------------------------------------------------------
  # Type resolution: AST.TypeRef -> internal type
  # ------------------------------------------------------------------

  @doc false
  @spec resolve_type(AST.TypeRef.t() | nil, map()) :: atom() | tuple()
  def resolve_type(%AST.TypeRef{name: name, params: []}, types) do
    case Map.get(@builtin_types, name) do
      nil ->
        # Enum names must resolve to {:enum, name} (not {:user_type, name}) so a
        # declared enum return type matches the {:enum, name} inferred for its
        # variant values. Before issue #259 this mismatch was hidden by the
        # "enum/user_type compatible with anything" lattice holes.
        case Map.get(types, name) do
          :enum -> {:enum, name}
          _ -> {:user_type, name}
        end

      type ->
        type
    end
  end

  def resolve_type(%AST.TypeRef{name: "Option", params: [inner]}, types) do
    {:option, resolve_type(inner, types)}
  end

  def resolve_type(%AST.TypeRef{name: "Result", params: [ok, err]}, types) do
    {:result, resolve_type(ok, types), resolve_type(err, types)}
  end

  def resolve_type(%AST.TypeRef{name: "List", params: [elem]}, types) do
    {:list, resolve_type(elem, types)}
  end

  def resolve_type(%AST.TypeRef{name: "Map", params: [k, v]}, types) do
    {:map, resolve_type(k, types), resolve_type(v, types)}
  end

  def resolve_type(%AST.TypeRef{name: "Set", params: [elem]}, types) do
    {:set, resolve_type(elem, types)}
  end

  def resolve_type(%AST.TypeRef{name: name}, _types) do
    {:user_type, name}
  end

  def resolve_type(nil, _types), do: :unknown

  # ------------------------------------------------------------------
  # Pass 1: Validate declarations
  # ------------------------------------------------------------------

  defp validate_declarations(declarations, env) do
    Enum.flat_map(declarations, fn decl -> validate_declaration(decl, env) end)
  end

  defp validate_declaration(%AST.Fn{params: params, return_type: return_type, meta: meta}, env) do
    errors = []

    # Check parameter types are known
    errors =
      errors ++
        Enum.flat_map(params, fn %AST.Field{type: type} ->
          validate_type_ref(type, env)
        end)

    # Check return type is known
    errors = errors ++ validate_type_ref(return_type, env)

    _ = meta
    errors
  end

  defp validate_declaration(%AST.TypeDecl{fields: fields}, env) do
    Enum.flat_map(fields, fn %AST.Field{type: type, annotations: annotations} ->
      type_errors = validate_type_ref(type, env)
      annotation_errors = validate_annotations(annotations, type, env)
      type_errors ++ annotation_errors
    end)
  end

  defp validate_declaration(%AST.EnumDecl{variants: variants}, env) do
    Enum.flat_map(variants, fn %AST.Variant{fields: fields} ->
      Enum.flat_map(fields, fn %AST.Field{type: type} ->
        validate_type_ref(type, env)
      end)
    end)
  end

  defp validate_declaration(%AST.Handler{source: source, meta: meta}, env) do
    required_capability = handler_required_capability(source)

    has_capability =
      Enum.any?(env.capabilities, fn %AST.Capability{kind: kind} ->
        kind == required_capability
      end)

    if has_capability do
      []
    else
      source_label = handler_source_label(source)
      deprecated_alias = deprecated_capability_alias(required_capability)

      has_deprecated_alias =
        deprecated_alias != nil and
          Enum.any?(env.capabilities, fn %AST.Capability{kind: kind} ->
            kind == deprecated_alias
          end)

      message =
        if has_deprecated_alias do
          "Capability '#{deprecated_alias}' was renamed to '#{required_capability}'. " <>
            "Update the declaration: capability #{required_capability}"
        else
          "Capability '#{required_capability}' required but not declared. " <>
            "#{source_label} handlers require this capability."
        end

      span = capability_insertion_span(env)

      [
        %Error{
          code: "E0012",
          severity: :error,
          message: message,
          location: location_from_meta(meta, env.file),
          fix_hint:
            "Add a capability declaration to the module: capability #{required_capability}",
          fix_code: "capability #{required_capability}",
          span: span,
          edit_kind: if(span, do: :insert_line)
        }
      ]
    end
  end

  defp validate_declaration(%AST.ToolDecl{input: input, output: output}, env) do
    # Check input field types are known
    input_errors =
      Enum.flat_map(input || [], fn %AST.Field{type: type, annotations: annotations} ->
        type_errors = validate_type_ref(type, env)
        annotation_errors = validate_annotations(annotations, type, env)
        type_errors ++ annotation_errors
      end)

    # Check output field types are known
    output_errors =
      Enum.flat_map(output || [], fn %AST.Field{type: type, annotations: annotations} ->
        type_errors = validate_type_ref(type, env)
        annotation_errors = validate_annotations(annotations, type, env)
        type_errors ++ annotation_errors
      end)

    input_errors ++ output_errors
  end

  defp validate_declaration(
         %AST.Supervisor{strategy: strategy, max_restarts: max_restarts} = sup,
         env
       ) do
    strategy_errors =
      case strategy do
        nil ->
          []

        s when s in [:one_for_one, :one_for_all, :rest_for_one] ->
          []

        _ ->
          [
            %Error{
              code: "E0040",
              severity: :error,
              message:
                "Invalid supervisor strategy '#{inspect(strategy)}', expected one_for_one, one_for_all, or rest_for_one",
              location: location_from_meta(sup.meta, env.file),
              fix_hint: "Use one of: one_for_one, one_for_all, rest_for_one",
              fix_code: "strategy: one_for_one"
            }
          ]
      end

    max_restart_errors =
      case max_restarts do
        nil ->
          []

        {count, period}
        when is_integer(count) and is_integer(period) and count > 0 and period > 0 ->
          []

        _ ->
          [
            %Error{
              code: "E0041",
              severity: :error,
              message:
                "Invalid max_restarts value, expected positive integers for count and period",
              location: location_from_meta(sup.meta, env.file),
              fix_hint: "Use format: max_restarts: N per Xs",
              fix_code: "max_restarts: 3 per 5s"
            }
          ]
      end

    children_errors =
      case sup.children do
        [] ->
          [
            %Error{
              code: "E0042",
              severity: :warning,
              message: "Supervisor '#{sup.name}' has no children",
              location: location_from_meta(sup.meta, env.file),
              fix_hint: "Add child declarations to the supervisor",
              fix_code: "child worker_fn { }"
            }
          ]

        _ ->
          []
      end

    strategy_errors ++ max_restart_errors ++ children_errors
  end

  defp validate_declaration(%AST.Scenario{}, _env), do: []
  defp validate_declaration(%AST.Golden{}, _env), do: []
  defp validate_declaration(%AST.Capability{}, _env), do: []
  defp validate_declaration(_, _env), do: []

  defp handler_required_capability("http"), do: "http.in"
  defp handler_required_capability("queue"), do: "queue.consume"
  defp handler_required_capability("schedule"), do: "schedule.trigger"
  defp handler_required_capability("topic"), do: "topic.consume"
  defp handler_required_capability(_), do: "unknown"

  # Pre-1.0 renames: declaring the old name gets a targeted migration hint.
  defp deprecated_capability_alias("queue.consume"), do: "queue.in"
  defp deprecated_capability_alias("schedule.trigger"), do: "schedule.in"
  defp deprecated_capability_alias(_), do: nil

  defp handler_source_label("http"), do: "HTTP"
  defp handler_source_label("queue"), do: "Queue"
  defp handler_source_label("schedule"), do: "Schedule"
  defp handler_source_label("topic"), do: "Topic"
  defp handler_source_label(source), do: source

  defp validate_type_ref(%AST.TypeRef{name: name, params: params, meta: meta}, env) do
    errors =
      if Map.has_key?(env.types, name) do
        []
      else
        # Only a real suggestion is an exact replacement for the type
        # name; the "TypeName" fallback is a template.
        span = if suggest_types(name, env) != "", do: span_from_meta(meta, name)

        [
          %Error{
            code: "E0024",
            severity: :error,
            message: "Unknown type '#{name}'",
            location: location_from_meta(meta, env.file),
            fix_hint: "Did you mean one of: #{suggest_types(name, env)}?",
            fix_code: first_type_suggestion(name, env),
            span: span,
            edit_kind: if(span, do: :replace)
          }
        ]
      end

    # Recursively validate type parameters
    errors ++ Enum.flat_map(params, &validate_type_ref(&1, env))
  end

  defp validate_type_ref(nil, _env), do: []

  # ------------------------------------------------------------------
  # Constraint annotation validation
  # ------------------------------------------------------------------

  defp validate_annotations(annotations, type, env) do
    resolved = resolve_type(type, env.types)

    Enum.flat_map(annotations, fn annotation ->
      validate_annotation(annotation, resolved, env)
    end)
  end

  defp validate_annotation(%AST.Annotation{name: "min", meta: meta}, type, env)
       when type not in [:int, :float] do
    [
      %Error{
        code: "E0025",
        severity: :error,
        message: "Annotation @min can only be applied to Int or Float, got #{format_type(type)}",
        location: location_from_meta(meta, env.file),
        fix_hint: "Remove @min or change the field type to Int or Float",
        fix_code: "Int"
      }
    ]
  end

  defp validate_annotation(%AST.Annotation{name: "max", meta: meta}, type, env)
       when type not in [:int, :float] do
    [
      %Error{
        code: "E0025",
        severity: :error,
        message: "Annotation @max can only be applied to Int or Float, got #{format_type(type)}",
        location: location_from_meta(meta, env.file),
        fix_hint: "Remove @max or change the field type to Int or Float",
        fix_code: "Int"
      }
    ]
  end

  defp validate_annotation(%AST.Annotation{name: "one_of", meta: meta}, type, env)
       when type != :string do
    [
      %Error{
        code: "E0025",
        severity: :error,
        message: "Annotation @one_of can only be applied to String, got #{format_type(type)}",
        location: location_from_meta(meta, env.file),
        fix_hint: "Remove @one_of or change the field type to String",
        fix_code: "String"
      }
    ]
  end

  # @primary and @unique are storage annotations — valid on any field type
  defp validate_annotation(%AST.Annotation{name: "primary"}, _type, _env), do: []
  defp validate_annotation(%AST.Annotation{name: "unique"}, _type, _env), do: []

  defp validate_annotation(_annotation, _type, _env), do: []

  # ------------------------------------------------------------------
  # Pass 2: Type-check function bodies
  # ------------------------------------------------------------------

  defp check_functions(declarations, env) do
    fns = Enum.filter(declarations, &match?(%AST.Fn{}, &1))
    Enum.flat_map(fns, &check_function(&1, env))
  end

  defp check_function(
         %AST.Fn{params: params, return_type: ret_type_ref, body: body, meta: meta},
         env
       ) do
    declared_return = resolve_type(ret_type_ref, env.types)

    # Build variable scope from parameters
    vars =
      params
      |> Enum.map(fn %AST.Field{name: name, type: type} ->
        {name, resolve_type(type, env.types)}
      end)
      |> Map.new()

    fn_env = %{env | variables: vars, current_fn_return_type: declared_return}

    {actual_return, errors} = infer_type(body, fn_env)

    # Check return type matches
    return_errors =
      if types_compatible?(actual_return, declared_return) do
        []
      else
        [
          %Error{
            code: "E0020",
            severity: :error,
            message:
              "Function return type mismatch: expected #{format_type(declared_return)}, got #{format_type(actual_return)}",
            location: location_from_meta(meta, env.file),
            fix_hint: "Change the return type or fix the function body",
            fix_code: "-> #{format_type(actual_return)}"
          }
        ]
      end

    errors ++ return_errors
  end

  # ------------------------------------------------------------------
  # Pass 2b: Type-check handler bodies
  # ------------------------------------------------------------------

  defp check_handlers(declarations, env) do
    handlers = Enum.filter(declarations, &match?(%AST.Handler{}, &1))
    Enum.flat_map(handlers, &check_handler(&1, env))
  end

  defp check_handler(%AST.Handler{param: param, body: body}, env) do
    # Add the request parameter to scope as :unknown (runtime-provided map)
    handler_env = %{env | variables: Map.put(env.variables, param, :unknown)}
    {_type, errors} = infer_type(body, handler_env)
    errors
  end

  # Tool `implement` bodies are executable too — they bind effect results and
  # build the tool's output. Run full inference with the tool's input fields in
  # scope so effect misuse there is a compile error, not a runtime crash (#253).
  defp check_tool_implement_inference(declarations, env) do
    declarations
    |> Enum.filter(&match?(%AST.ToolDecl{implement: impl} when not is_nil(impl), &1))
    |> Enum.flat_map(fn %AST.ToolDecl{input: input, implement: implement} ->
      input_vars =
        (input || [])
        |> Enum.map(fn %AST.Field{name: name, type: type} ->
          {name, resolve_type(type, env.types)}
        end)
        |> Map.new()

      {_type, errors} =
        infer_type(implement, %{env | variables: Map.merge(env.variables, input_vars)})

      errors
    end)
  end

  # ------------------------------------------------------------------
  # Pass 2d: Type-check test / scenario / golden bodies (#253)
  # ------------------------------------------------------------------

  # Test bodies are executable: they bind effect results, call tools, and
  # assert. Before #253 they ran the capability/interpolation walks but skipped
  # full inference, so a soundness bug (a missing `!`/`?`, `!`-on-`Option`,
  # `String +`) slipped through `test` blocks. Run the same inference the rest
  # of the pipeline uses; a scenario's `given` bindings are in scope for its
  # `expect` body.
  defp check_test_inference(declarations, env) do
    Enum.flat_map(declarations, fn
      %AST.Test{body: body} ->
        {_type, errors} = infer_type(body, env)
        errors

      %AST.Golden{body: body} ->
        {_type, errors} = infer_type(body, env)
        errors

      %AST.Scenario{given_vars: given_vars, expect_body: body} ->
        {vars, given_errors} =
          Enum.reduce(given_vars || [], {env.variables, []}, fn {name, value}, {vars, errs} ->
            {value_type, value_errors} = infer_type(value, %{env | variables: vars})
            {Map.put(vars, name, value_type), errs ++ value_errors}
          end)

        {_type, errors} = infer_type(body, %{env | variables: vars})
        given_errors ++ errors

      _ ->
        []
    end)
  end

  # ------------------------------------------------------------------
  # Type inference
  # ------------------------------------------------------------------

  # Block: type is the type of the last expression
  defp infer_type(%AST.Block{expressions: []}, _env), do: {:unknown, []}

  defp infer_type(%AST.Block{expressions: exprs}, env) do
    infer_block(exprs, env, {:unknown, []})
  end

  # Literals
  defp infer_type(%AST.IntLit{}, _env), do: {:int, []}
  defp infer_type(%AST.FloatLit{}, _env), do: {:float, []}
  defp infer_type(%AST.BoolLit{}, _env), do: {:bool, []}

  defp infer_type(%AST.StringLit{segments: segments}, env) do
    # Check interpolation references are valid
    errors =
      segments
      |> Enum.flat_map(fn
        {:interpolation, token} -> check_interpolation(token, env)
        {:literal, _} -> []
      end)

    {:string, errors}
  end

  # Identifier
  defp infer_type(%AST.Identifier{name: name, meta: meta}, env) do
    cond do
      Map.has_key?(env.variables, name) ->
        {Map.get(env.variables, name), []}

      Map.has_key?(env.functions, name) ->
        # A function reference — type is determined at call site
        {:unknown, []}

      Map.has_key?(env.enums, name) ->
        # Enum variant reference (simple, no data)
        {{:enum, name}, []}

      # Uppercase name could be a type/enum constructor or variant
      String.match?(name, ~r/^[A-Z]/) ->
        # Could be an enum variant — check all enums for this variant name
        case find_enum_variant(name, env) do
          {:ok, enum_name} ->
            {{:enum, enum_name}, []}

          :error ->
            if name in ["Ok", "Err"] do
              {:unknown, []}
            else
              {:unknown, [unknown_constructor_error(name, meta, meta, env)]}
            end
        end

      # `return` is not a Skein construct — give a targeted hint instead of
      # the generic did-you-mean suggestion
      name == "return" ->
        {:unknown,
         [
           %Error{
             code: "E0010",
             severity: :error,
             message: "Unknown identifier 'return'",
             location: location_from_meta(meta, env.file),
             fix_hint:
               "Skein has no 'return' statement; a function returns the value of its last expression",
             fix_code: ""
           }
         ]}

      # Conditional/loop keywords from other languages that Skein deliberately
      # omits — steer to `match` rather than the misleading did-you-mean hint
      # that treats them as misspelled variables (skein-testing #5).
      Map.has_key?(@absent_keyword_hints, name) ->
        {:unknown,
         [
           %Error{
             code: "E0010",
             severity: :error,
             message: "'#{name}' is not a Skein construct",
             location: location_from_meta(meta, env.file),
             fix_hint: Map.fetch!(@absent_keyword_hints, name),
             fix_code: "match condition {\n  true -> ...\n  false -> ...\n}"
           }
         ]}

      true ->
        suggestion = suggest_identifier(name, env)

        fix_hint =
          if suggestion,
            do: "Did you mean '#{suggestion}'?",
            else: "Did you mean to declare this variable?"

        fix_code = suggestion || "let #{name} = value"

        # A real suggestion is an exact replacement for the identifier;
        # the let-skeleton fallback is only a template.
        span = if suggestion, do: span_from_meta(meta, name)

        {:unknown,
         [
           %Error{
             code: "E0010",
             severity: :error,
             message: "Unknown identifier '#{name}'",
             location: location_from_meta(meta, env.file),
             fix_hint: fix_hint,
             fix_code: fix_code,
             span: span,
             edit_kind: if(span, do: :replace)
           }
         ]}
    end
  end

  # Binary operations
  defp infer_type(%AST.BinaryOp{op: op, left: left, right: right, meta: meta}, env)
       when op in [:+, :-, :*, :/] do
    {left_type, left_errors} = infer_type(left, env)
    {right_type, right_errors} = infer_type(right, env)

    cond do
      left_type == :unknown or right_type == :unknown ->
        {:unknown, left_errors ++ right_errors}

      left_type in [:int, :float] and right_type in [:int, :float] ->
        result_type = if left_type == :float or right_type == :float, do: :float, else: :int
        {result_type, left_errors ++ right_errors}

      true ->
        # `+`/`-`/`*`/`/` are numeric only. `String + String` used to type-check
        # and then crash at runtime (no Erlang `+` for binaries) — #252; string
        # building is done with interpolation, not `+`.
        string_concat? = op == :+ and (left_type == :string or right_type == :string)

        fix_hint =
          if string_concat?,
            do: "Skein has no string '+'; build strings with interpolation: \"${a}${b}\"",
            else: "Ensure both operands are Int or Float"

        {
          :unknown,
          left_errors ++
            right_errors ++
            [
              %Error{
                code: "E0020",
                severity: :error,
                message:
                  "Operator '#{op}' requires numeric operands, got #{format_type(left_type)} and #{format_type(right_type)}",
                location: location_from_meta(meta, env.file),
                fix_hint: fix_hint,
                fix_code:
                  if(string_concat?,
                    do: ~s("${a}${b}"),
                    else: "// Convert both operands of '#{op}' to Int or Float"
                  )
              }
            ]
        }
    end
  end

  # Comparison operators
  defp infer_type(%AST.BinaryOp{op: op, left: left, right: right, meta: meta}, env)
       when op in [:==, :!=, :<, :>, :<=, :>=] do
    {left_type, left_errors} = infer_type(left, env)
    {right_type, right_errors} = infer_type(right, env)

    cond do
      left_type == :unknown or right_type == :unknown ->
        {:bool, left_errors ++ right_errors}

      # Equality can compare same types
      op in [:==, :!=] and types_compatible?(left_type, right_type) ->
        {:bool, left_errors ++ right_errors}

      # Ordering requires comparable types (numeric)
      op in [:<, :>, :<=, :>=] and left_type in [:int, :float] and right_type in [:int, :float] ->
        {:bool, left_errors ++ right_errors}

      true ->
        {:bool,
         left_errors ++
           right_errors ++
           [
             %Error{
               code: "E0020",
               severity: :error,
               message:
                 "Operator '#{op}' cannot compare #{format_type(left_type)} and #{format_type(right_type)}",
               location: location_from_meta(meta, env.file),
               fix_hint: "Ensure operands have compatible types",
               fix_code: "// Compare values of the same type with '#{op}'"
             }
           ]}
    end
  end

  # Logical operators
  defp infer_type(%AST.BinaryOp{op: op, left: left, right: right, meta: meta}, env)
       when op in [:&&, :||] do
    {left_type, left_errors} = infer_type(left, env)
    {right_type, right_errors} = infer_type(right, env)

    errors =
      cond do
        left_type == :unknown or right_type == :unknown ->
          []

        left_type != :bool ->
          [
            %Error{
              code: "E0020",
              severity: :error,
              message: "Operator '#{op}' requires Bool operands, got #{format_type(left_type)}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Ensure both operands are Bool",
              fix_code: "// Use Bool operands with '#{op}'"
            }
          ]

        right_type != :bool ->
          [
            %Error{
              code: "E0020",
              severity: :error,
              message: "Operator '#{op}' requires Bool operands, got #{format_type(right_type)}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Ensure both operands are Bool",
              fix_code: "// Use Bool operands with '#{op}'"
            }
          ]

        true ->
          []
      end

    {:bool, left_errors ++ right_errors ++ errors}
  end

  # Unary not
  defp infer_type(%AST.UnaryOp{op: :not, operand: operand, meta: meta}, env) do
    {operand_type, operand_errors} = infer_type(operand, env)

    errors =
      if operand_type in [:bool, :unknown] do
        []
      else
        [
          %Error{
            code: "E0020",
            severity: :error,
            message: "Operator '!' requires Bool operand, got #{format_type(operand_type)}",
            location: location_from_meta(meta, env.file),
            fix_hint: "Ensure the operand is Bool",
            fix_code: "// Use a Bool operand with '!'"
          }
        ]
      end

    {:bool, operand_errors ++ errors}
  end

  # Unary minus (arithmetic negation)
  defp infer_type(%AST.UnaryOp{op: :negate, operand: operand, meta: meta}, env) do
    {operand_type, operand_errors} = infer_type(operand, env)

    case operand_type do
      :int ->
        {:int, operand_errors}

      :float ->
        {:float, operand_errors}

      :unknown ->
        {:unknown, operand_errors}

      other ->
        {:unknown,
         operand_errors ++
           [
             %Error{
               code: "E0020",
               severity: :error,
               message:
                 "Operator '-' (negation) requires Int or Float operand, got #{format_type(other)}",
               location: location_from_meta(meta, env.file),
               fix_hint: "Negate only Int or Float values",
               fix_code: "-0"
             }
           ]}
    end
  end

  # Unwrap (!) operator
  defp infer_type(%AST.UnaryOp{op: :unwrap, operand: operand, meta: meta}, env) do
    {operand_type, operand_errors} = infer_type(operand, env)

    case operand_type do
      {:result, ok_type, _err_type} ->
        {ok_type, operand_errors}

      :unknown ->
        {:unknown, operand_errors}

      other ->
        {:unknown,
         operand_errors ++
           [
             %Error{
               code: "E0022",
               severity: :error,
               message: "Operator '!' (unwrap) requires a Result type, got #{format_type(other)}",
               location: location_from_meta(meta, env.file),
               fix_hint: "Use '!' only on Result values, or wrap the value in Result.ok()",
               fix_code: "Result.ok(value)"
             }
           ]}
    end
  end

  # Propagate (?) operator
  defp infer_type(%AST.UnaryOp{op: :propagate, operand: operand, meta: meta}, env) do
    {operand_type, operand_errors} = infer_type(operand, env)

    type_errors =
      case operand_type do
        {:result, _, _} ->
          []

        :unknown ->
          []

        other ->
          [
            %Error{
              code: "E0023",
              severity: :error,
              message:
                "Operator '?' (propagate) requires a Result type, got #{format_type(other)}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Use '?' only on Result values",
              fix_code: "Result.ok(value)"
            }
          ]
      end

    # Check that the enclosing function returns a Result type
    fn_return_errors =
      case env.current_fn_return_type do
        {:result, _, _} ->
          []

        nil ->
          []

        :unknown ->
          []

        other_ret ->
          [
            %Error{
              code: "E0023",
              severity: :error,
              message:
                "Operator '?' used in function that returns #{format_type(other_ret)}, " <>
                  "but '?' requires the enclosing function to return a Result type",
              location: location_from_meta(meta, env.file),
              fix_hint: "Change the function return type to Result or use '!' to unwrap instead",
              fix_code: "-> Result[#{format_type(other_ret)}, String]"
            }
          ]
      end

    ok_type =
      case operand_type do
        {:result, ok, _} -> ok
        _ -> :unknown
      end

    {ok_type, operand_errors ++ type_errors ++ fn_return_errors}
  end

  # Match expression
  defp infer_type(%AST.Match{subject: subject, arms: arms, meta: meta}, env) do
    {subject_type, subject_errors} = infer_type(subject, env)

    # Infer types of all arms
    arm_results = Enum.map(arms, &infer_match_arm(&1, subject_type, env))
    arm_types = Enum.map(arm_results, &elem(&1, 0))
    arm_errors = Enum.flat_map(arm_results, &elem(&1, 1))

    # Unify the arm types: the result type is their join, and arms that cannot
    # be unified produce an E0020. Same-headed compound types (Result/List/...)
    # whose inner types diverge widen the divergent component to :unknown rather
    # than erroring — e.g. a discarded handler match whose arms return
    # Result[String, StoreError] and Result[String, HttpError] (spec §8.3).
    {result_type, consistency_errors} = unify_arm_types(arm_types, meta, env)

    # Check exhaustiveness (enum-typed params resolve as {:user_type, name};
    # normalize declared enum names so those matches are checked too)
    exhaustiveness_warnings =
      check_exhaustiveness(normalize_match_subject_type(subject_type, env), arms, meta, env)

    {result_type, subject_errors ++ arm_errors ++ consistency_errors ++ exhaustiveness_warnings}
  end

  # Function call
  defp infer_type(%AST.Call{target: target, args: args, meta: meta} = call, env) do
    args_results = Enum.map(args, &infer_type(&1, env))
    args_errors = Enum.flat_map(args_results, &elem(&1, 1))
    type_param = Map.get(call, :type_param)

    case target do
      # store.<table>.<method>(...) — typed as Result so a missing !/? is a
      # compile error (spec §6.2, skein-testing#1).
      %AST.FieldAccess{
        subject: %AST.FieldAccess{subject: %AST.Identifier{name: "store"}, field: _table},
        field: method
      }
      when method in @store_methods ->
        {Map.get(@store_return_types, method, :unknown), args_errors}

      %AST.Identifier{name: name} when is_map_key(env.functions, name) ->
        fn_info = Map.get(env.functions, name)
        expected_arity = length(fn_info.params)
        actual_arity = length(args)

        arity_errors =
          if expected_arity != actual_arity do
            [
              %Error{
                code: "E0020",
                severity: :error,
                message:
                  "Function '#{name}' expects #{expected_arity} argument(s), got #{actual_arity}",
                location: location_from_meta(meta, env.file),
                fix_hint: "Pass #{expected_arity} argument(s) to '#{name}'",
                fix_code: call_skeleton(name, expected_arity)
              }
            ]
          else
            []
          end

        {fn_info.return_type, args_errors ++ arity_errors}

      # Stdlib call: Module.function(args)
      %AST.FieldAccess{subject: %AST.Identifier{name: mod_name}, field: fn_name}
      when mod_name in @stdlib_modules ->
        mod_registry = Map.get(@stdlib_registry, mod_name)

        case Map.get(mod_registry, fn_name) do
          nil ->
            {
              :unknown,
              args_errors ++
                [
                  %Error{
                    code: "E0010",
                    severity: :error,
                    message: "Unknown function '#{mod_name}.#{fn_name}'",
                    location: location_from_meta(meta, env.file),
                    fix_hint: "Available functions: #{Enum.join(Map.keys(mod_registry), ", ")}",
                    fix_code: "#{mod_name}.#{closest_name(fn_name, Map.keys(mod_registry))}"
                  }
                ]
            }

          fn_info ->
            expected_arity = length(fn_info.params)
            actual_arity = length(args)

            arity_errors =
              if expected_arity != actual_arity do
                [
                  %Error{
                    code: "E0020",
                    severity: :error,
                    message:
                      "Function '#{mod_name}.#{fn_name}' expects #{expected_arity} argument(s), got #{actual_arity}",
                    location: location_from_meta(meta, env.file),
                    fix_hint: "Pass #{expected_arity} argument(s) to '#{mod_name}.#{fn_name}'",
                    fix_code: call_skeleton("#{mod_name}.#{fn_name}", expected_arity)
                  }
                ]
              else
                []
              end

            # Type-check arguments against expected parameter types
            arg_types = Enum.map(args_results, &elem(&1, 0))

            type_errors =
              if expected_arity == actual_arity do
                Enum.zip([fn_info.params, arg_types, 0..max(actual_arity - 1, 0)//1])
                |> Enum.flat_map(fn {expected, actual, _idx} ->
                  if actual != :unknown and not types_compatible?(expected, actual) do
                    [
                      %Error{
                        code: "E0020",
                        severity: :error,
                        message:
                          "Type mismatch in call to '#{mod_name}.#{fn_name}': expected #{format_type(expected)}, got #{format_type(actual)}",
                        location: location_from_meta(meta, env.file),
                        fix_hint: "Pass a value of type #{format_type(expected)}",
                        fix_code: "// Pass a #{format_type(expected)} value"
                      }
                    ]
                  else
                    []
                  end
                end)
              else
                []
              end

            {fn_info.return_type, args_errors ++ arity_errors ++ type_errors}
        end

      # Qualified call with a non-stdlib UpperIdent head: either a variant
      # constructor (Enum.Variant(args)) or a cross-module call attempt.
      # Functions are module-private (spec section 3.1) — tools are the only
      # cross-module seam — so the latter is a structured E0016, never a
      # silent fallthrough. Local enum/type names and tool error names are
      # exempt: they are not module references.
      %AST.FieldAccess{subject: %AST.Identifier{name: mod_name}, field: fn_name} ->
        cond do
          Map.has_key?(env.enums, mod_name) ->
            {type, ctor_errors} =
              check_variant_construction(mod_name, fn_name, args, args_results, meta, env)

            {type, args_errors ++ ctor_errors}

          cross_module_call_head?(mod_name, env) ->
            {:unknown,
             args_errors ++ [cross_module_call_error(mod_name, fn_name, length(args), meta, env)]}

          effect_namespace?(mod_name) and effect_method?(mod_name, fn_name) ->
            {effect_call_return_type(mod_name, fn_name, type_param, env),
             args_errors ++ effect_call_arity_errors(mod_name, fn_name, args, meta, env)}

          # A method that is not part of a known effect namespace's surface is a
          # structured error, not a silent :unknown that crashes in codegen
          # (skein-testing#33).
          effect_namespace?(mod_name) ->
            {:unknown, args_errors ++ [unknown_effect_method_error(mod_name, fn_name, meta, env)]}

          # req.json[T] / msg.json[T] on a handler param — typed Result[T, _]
          # so bare use (no !/?) is a compile error like any other effect.
          fn_name == "json" and match?(%AST.TypeRef{}, type_param) ->
            {{:result, resolve_type(type_param, env.types), :unknown}, args_errors}

          true ->
            {:unknown, args_errors}
        end

      # Bare constructor call: Ok(x), Err(e), or Variant(args)
      %AST.Identifier{name: <<c, _::binary>> = name, meta: target_meta} when c in ?A..?Z ->
        cond do
          name in ["Ok", "Err"] ->
            arity_errors =
              if length(args) == 1 do
                []
              else
                [
                  %Error{
                    code: "E0020",
                    severity: :error,
                    message: "Constructor '#{name}' expects 1 argument, got #{length(args)}",
                    location: location_from_meta(meta, env.file),
                    fix_hint: "Wrap exactly one value: #{name}(value)",
                    fix_code: "#{name}(value)"
                  }
                ]
              end

            # Infer the half of the Result the constructor pins; the other half
            # stays :unknown so it unifies with whatever the declared type asks
            # for (issue #259: Ok/Err must not infer a bare :unknown that passes
            # against any declared type). With exactly one arg we know its type;
            # otherwise the arity error already fired, so fall back to :unknown.
            inferred =
              case args_results do
                [{arg_type, _}] when name == "Ok" -> {:result, arg_type, :unknown}
                [{arg_type, _}] when name == "Err" -> {:result, :unknown, arg_type}
                _ -> :unknown
              end

            {inferred, args_errors ++ arity_errors}

          true ->
            case find_enum_variant(name, env) do
              {:ok, enum_name} ->
                {type, ctor_errors} =
                  check_variant_construction(enum_name, name, args, args_results, meta, env)

                {type, args_errors ++ ctor_errors}

              :error ->
                {:unknown,
                 args_errors ++ [unknown_constructor_error(name, meta, target_meta, env)]}
            end
        end

      _ ->
        # Unknown function call — can't infer type
        {:unknown, args_errors}
    end
  end

  # Pipe expression: the piped value becomes the first argument of the
  # right-hand call (spec section 4 rule 8), so check the desugared call.
  defp infer_type(%AST.Pipe{left: left, right: %AST.Call{args: args} = call}, env) do
    infer_type(%{call | args: [left | args]}, env)
  end

  defp infer_type(%AST.Pipe{left: left, right: right}, env) do
    {_left_type, left_errors} = infer_type(left, env)
    {right_type, right_errors} = infer_type(right, env)
    {right_type, left_errors ++ right_errors}
  end

  # Enum variant reference: Status.Active — zero-field construction.
  # The head must be a declared enum NAME (a binding of the same name wins).
  defp infer_type(
         %AST.FieldAccess{
           subject: %AST.Identifier{name: enum_name},
           field: <<c, _::binary>> = variant_name,
           meta: meta
         },
         env
       )
       when c in ?A..?Z do
    cond do
      Map.has_key?(env.variables, enum_name) ->
        infer_field_access_type(
          %AST.Identifier{name: enum_name, meta: meta},
          variant_name,
          meta,
          env
        )

      Map.has_key?(env.enums, enum_name) ->
        %AST.EnumDecl{variants: variants} = Map.fetch!(env.enums, enum_name)

        case Enum.find(variants, &(&1.name == variant_name)) do
          nil ->
            {:unknown, [unknown_variant_error(enum_name, variant_name, variants, meta, env)]}

          %AST.Variant{fields: []} ->
            {{:enum, enum_name}, []}

          %AST.Variant{fields: fields} ->
            {{:enum, enum_name},
             [
               %Error{
                 code: "E0020",
                 severity: :error,
                 message:
                   "Variant '#{enum_name}.#{variant_name}' has #{length(fields)} field(s) — construct it with arguments",
                 location: location_from_meta(meta, env.file),
                 fix_hint: variant_construction_hint(enum_name, variant_name, fields),
                 fix_code: variant_construction_skeleton(enum_name, variant_name, fields)
               }
             ]}
        end

      true ->
        infer_field_access_type(
          %AST.Identifier{name: enum_name, meta: meta},
          variant_name,
          meta,
          env
        )
    end
  end

  # Field access
  defp infer_type(%AST.FieldAccess{subject: subject, field: field, meta: meta}, env) do
    infer_field_access_type(subject, field, meta, env)
  end

  # FnRef
  defp infer_type(%AST.FnRef{}, _env) do
    {:unknown, []}
  end

  # Let (standalone — shouldn't appear outside blocks, but handle gracefully)
  defp infer_type(%AST.Let{value: value}, env) do
    infer_type(value, env)
  end

  # List literal: List[T] is homogeneous (issue #259). We infer the element
  # type from the first element whose type is known, then flag every element
  # whose (known) type is incompatible. An empty or all-:unknown list infers
  # List[:unknown], which unifies with any declared List[_].
  defp infer_type(%AST.ListLit{elements: elements, meta: meta}, env) do
    results = Enum.map(elements, &infer_type(&1, env))
    element_errors = Enum.flat_map(results, &elem(&1, 1))
    element_types = Enum.map(results, &elem(&1, 0))

    canonical = Enum.find(element_types, :unknown, &(&1 != :unknown))

    homogeneity_errors =
      element_types
      |> Enum.filter(fn t -> t != :unknown and not types_compatible?(canonical, t) end)
      |> Enum.map(fn t ->
        %Error{
          code: "E0020",
          severity: :error,
          message:
            "List elements must share one type: expected #{format_type(canonical)}, got #{format_type(t)}",
          location: location_from_meta(meta, env.file),
          fix_hint:
            "Every element of a List[#{format_type(canonical)}] must be a #{format_type(canonical)}",
          fix_code: "// Use elements that are all #{format_type(canonical)}"
        }
      end)

    {{:list, canonical}, element_errors ++ homogeneity_errors}
  end

  defp infer_type(%AST.MapLit{entries: entries}, env) do
    errors =
      Enum.flat_map(entries, fn {_key, value} ->
        {_type, errs} = infer_type(value, env)
        errs
      end)

    {{:map, :string, :unknown}, errors}
  end

  # Nominal record literal: TypeName { field: expr, ... }. Checked field-by-field
  # against the named type's declaration: unknown fields, missing required
  # (non-Option) fields, and per-field type mismatches are all structured errors.
  defp infer_type(%AST.RecordLit{type_name: name, fields: fields, meta: meta}, env) do
    field_results = Enum.map(fields, fn {fname, value} -> {fname, infer_type(value, env)} end)
    value_errors = Enum.flat_map(field_results, fn {_n, {_t, errs}} -> errs end)

    case Map.get(env.types, name) do
      %AST.TypeDecl{fields: decl_fields} ->
        decl_map = Map.new(decl_fields, fn %AST.Field{name: n} = f -> {n, f} end)
        provided_names = MapSet.new(field_results, fn {n, _} -> n end)

        unknown_errors =
          for {fname, _} <- field_results, not Map.has_key?(decl_map, fname) do
            %Error{
              code: "E0020",
              severity: :error,
              message: "Unknown field '#{fname}' for type '#{name}'",
              location: location_from_meta(meta, env.file),
              fix_hint:
                "'#{name}' has fields: #{decl_map |> Map.keys() |> Enum.sort() |> Enum.join(", ")}",
              fix_code: nil
            }
          end

        missing_errors =
          for {fname, %AST.Field{} = f} <- decl_map,
              not MapSet.member?(provided_names, fname),
              not optional_field?(f, env) do
            %Error{
              code: "E0020",
              severity: :error,
              message: "Missing required field '#{fname}' in '#{name}' literal",
              location: location_from_meta(meta, env.file),
              fix_hint: "Add '#{fname}: ...' to the #{name} literal",
              fix_code: "#{fname}: ..."
            }
          end

        mismatch_errors =
          Enum.flat_map(field_results, fn {fname, {vtype, _}} ->
            case Map.get(decl_map, fname) do
              %AST.Field{type: ftype} ->
                expected = resolve_type(ftype, env.types)

                if types_compatible?(expected, vtype) do
                  []
                else
                  [
                    %Error{
                      code: "E0020",
                      severity: :error,
                      message:
                        "Field '#{fname}' of '#{name}' expects #{format_type(expected)}, got #{format_type(vtype)}",
                      location: location_from_meta(meta, env.file),
                      fix_hint: "Provide a #{format_type(expected)} for '#{fname}'",
                      fix_code: nil
                    }
                  ]
                end

              nil ->
                []
            end
          end)

        {{:user_type, name}, value_errors ++ unknown_errors ++ missing_errors ++ mismatch_errors}

      :enum ->
        {{:enum, name},
         value_errors ++
           [
             %Error{
               code: "E0020",
               severity: :error,
               message: "Cannot construct enum '#{name}' with record syntax",
               location: location_from_meta(meta, env.file),
               fix_hint: "Use a variant, e.g. #{name}.SomeVariant",
               fix_code: nil
             }
           ]}

      _ ->
        {:unknown,
         value_errors ++
           [
             %Error{
               code: "E0024",
               severity: :error,
               message: "Unknown type '#{name}' in record literal",
               location: location_from_meta(meta, env.file),
               fix_hint: "Did you mean one of: #{suggest_types(name, env)}?",
               fix_code: first_type_suggestion(name, env)
             }
           ]}
    end
  end

  # Catch-all
  defp infer_type(_expr, _env) do
    {:unknown, []}
  end

  # A record field is optional when its declared type is Option[...].
  defp optional_field?(%AST.Field{type: type}, env) do
    match?({:option, _}, resolve_type(type, env.types))
  end

  defp infer_field_access_type(subject, field, meta, env) do
    {subject_type, subject_errors} = infer_type(subject, env)

    case subject_type do
      :unknown ->
        {:unknown, subject_errors}

      {:user_type, type_name} ->
        case Map.get(env.types, type_name) do
          %AST.TypeDecl{fields: fields} ->
            case Enum.find(fields, &(&1.name == field)) do
              %AST.Field{type: type_ref} ->
                {resolve_type(type_ref, env.types), subject_errors}

              nil ->
                {
                  :unknown,
                  subject_errors ++
                    [
                      %Error{
                        code: "E0020",
                        severity: :error,
                        message: "Type '#{type_name}' has no field '#{field}'",
                        location: location_from_meta(meta, env.file),
                        fix_hint: "Available fields: #{Enum.map_join(fields, ", ", & &1.name)}",
                        fix_code: closest_name(field, Enum.map(fields, & &1.name))
                      }
                    ]
                }
            end

          _ ->
            {:unknown, subject_errors}
        end

      other ->
        {
          :unknown,
          subject_errors ++
            [
              %Error{
                code: "E0020",
                severity: :error,
                message: "Cannot access field '#{field}' on type #{format_type(other)}",
                location: location_from_meta(meta, env.file),
                fix_hint: "Field access is only supported on user-defined types",
                fix_code: "// Access fields only on user-defined types"
              }
            ]
        }
    end
  end

  # Validates Enum.Variant(args) / Variant(args) construction: the variant
  # must exist and the arguments must match its declared fields.
  defp check_variant_construction(enum_name, variant_name, args, args_results, meta, env) do
    %AST.EnumDecl{variants: variants} = Map.fetch!(env.enums, enum_name)

    case Enum.find(variants, &(&1.name == variant_name)) do
      nil ->
        {:unknown, [unknown_variant_error(enum_name, variant_name, variants, meta, env)]}

      %AST.Variant{fields: fields} ->
        expected_arity = length(fields)
        actual_arity = length(args)

        cond do
          expected_arity != actual_arity ->
            {{:enum, enum_name},
             [
               %Error{
                 code: "E0020",
                 severity: :error,
                 message:
                   "Variant '#{enum_name}.#{variant_name}' expects #{expected_arity} argument(s), got #{actual_arity}",
                 location: location_from_meta(meta, env.file),
                 fix_hint: variant_construction_hint(enum_name, variant_name, fields),
                 fix_code: variant_construction_skeleton(enum_name, variant_name, fields)
               }
             ]}

          true ->
            arg_types = Enum.map(args_results, &elem(&1, 0))

            type_errors =
              Enum.zip(fields, arg_types)
              |> Enum.flat_map(fn {%AST.Field{name: field_name, type: type_ref}, actual} ->
                expected = resolve_type(type_ref, env.types)

                if actual != :unknown and not types_compatible?(expected, actual) do
                  [
                    %Error{
                      code: "E0020",
                      severity: :error,
                      message:
                        "Type mismatch in '#{enum_name}.#{variant_name}': field '#{field_name}' expects #{format_type(expected)}, got #{format_type(actual)}",
                      location: location_from_meta(meta, env.file),
                      fix_hint: "Pass a #{format_type(expected)} for '#{field_name}'",
                      fix_code: variant_construction_skeleton(enum_name, variant_name, fields)
                    }
                  ]
                else
                  []
                end
              end)

            {{:enum, enum_name}, type_errors}
        end
    end
  end

  defp unknown_variant_error(enum_name, variant_name, variants, meta, env) do
    variant_names = Enum.map(variants, & &1.name)

    %Error{
      code: "E0010",
      severity: :error,
      message: "Enum '#{enum_name}' has no variant '#{variant_name}'",
      location: location_from_meta(meta, env.file),
      fix_hint: "Declared variants: #{Enum.join(variant_names, ", ")}",
      fix_code: "#{enum_name}.#{closest_name(variant_name, variant_names)}"
    }
  end

  # `meta` locates the error; `name_meta` locates the constructor name
  # itself (a Call's meta points at the lparen, its target's at the name).
  defp unknown_constructor_error(name, meta, name_meta, env) do
    candidates =
      env.enums
      |> Enum.flat_map(fn {_enum, %AST.EnumDecl{variants: variants}} ->
        Enum.map(variants, & &1.name)
      end)

    span = span_from_meta(name_meta, name)

    %Error{
      code: "E0010",
      severity: :error,
      message: "Unknown constructor '#{name}' — no declared enum has this variant",
      location: location_from_meta(meta, env.file),
      fix_hint:
        case candidates do
          [] -> "Declare an enum with this variant, or use Ok(value)/Err(reason)"
          names -> "Declared variants: #{Enum.join(Enum.uniq(names), ", ")}"
        end,
      fix_code: closest_name(name, candidates ++ ["Ok", "Err"]),
      span: span,
      edit_kind: if(span, do: :replace)
    }
  end

  defp variant_construction_hint(enum_name, variant_name, []) do
    "'#{enum_name}.#{variant_name}' takes no arguments"
  end

  defp variant_construction_hint(enum_name, variant_name, fields) do
    "Construct it as #{variant_construction_skeleton(enum_name, variant_name, fields)}"
  end

  defp variant_construction_skeleton(enum_name, variant_name, []) do
    "#{enum_name}.#{variant_name}"
  end

  defp variant_construction_skeleton(enum_name, variant_name, fields) do
    args = Enum.map_join(fields, ", ", & &1.name)
    "#{enum_name}.#{variant_name}(#{args})"
  end

  # ------------------------------------------------------------------
  # Block inference (separate from infer_type to avoid grouping warning)
  # ------------------------------------------------------------------

  defp infer_block([], _env, acc), do: acc

  defp infer_block([%AST.Let{name: name, value: value} | rest], env, {_prev_type, prev_errors}) do
    {val_type, val_errors} = infer_type(value, env)
    new_env = %{env | variables: Map.put(env.variables, name, val_type)}
    infer_block(rest, new_env, {val_type, prev_errors ++ val_errors})
  end

  defp infer_block([expr], env, {_prev_type, prev_errors}) do
    {expr_type, expr_errors} = infer_type(expr, env)
    {expr_type, prev_errors ++ expr_errors}
  end

  defp infer_block([expr | rest], env, {_prev_type, prev_errors}) do
    {_expr_type, expr_errors} = infer_type(expr, env)
    infer_block(rest, env, {:unknown, prev_errors ++ expr_errors})
  end

  # ------------------------------------------------------------------
  # Match arm inference
  # ------------------------------------------------------------------

  defp infer_match_arm(
         %AST.MatchArm{pattern: pattern, guard: guard, body: body},
         subject_type,
         env
       ) do
    # Bind pattern variables into scope with type info from the subject
    new_env = bind_pattern(pattern, subject_type, env)
    guard_errors = check_guard(guard, new_env)
    {body_type, body_errors} = infer_type(body, new_env)
    {body_type, guard_errors ++ body_errors}
  end

  # ------------------------------------------------------------------
  # Match guards
  # ------------------------------------------------------------------

  # Binary operators whose codegen lowers to a single guard-safe erlang call.
  # `/` is excluded: its codegen emits a runtime float/int dispatch `case`,
  # which is not a valid Core Erlang guard.
  @guard_safe_binary_ops [:+, :-, :*, :==, :!=, :<, :>, :<=, :>=, :&&, :||]
  @guard_safe_unary_ops [:not, :negate]

  defp check_guard(nil, _env), do: []

  defp check_guard(guard, env) do
    safety_errors = guard_safety_errors(guard, env)
    {guard_type, type_errors} = infer_type(guard, env)

    bool_errors =
      if guard_type in [:bool, :unknown] do
        []
      else
        [
          %Error{
            code: "E0020",
            severity: :error,
            message: "Match guard must be Bool, got #{format_type(guard_type)}",
            location: location_from_meta(guard_meta(guard), env.file),
            fix_hint: "Use a comparison or boolean expression in the guard",
            fix_code: nil
          }
        ]
      end

    safety_errors ++ type_errors ++ bool_errors
  end

  # Guards must lower to Core Erlang clause guards, so only the guard-safe
  # subset is allowed: literals, bindings, field access, comparisons,
  # boolean operators, and +/-/* arithmetic. No calls, effects, or blocks.
  defp guard_safety_errors(%AST.IntLit{}, _env), do: []
  defp guard_safety_errors(%AST.FloatLit{}, _env), do: []
  defp guard_safety_errors(%AST.BoolLit{}, _env), do: []
  defp guard_safety_errors(%AST.Identifier{}, _env), do: []

  defp guard_safety_errors(%AST.StringLit{segments: segments, meta: meta}, env) do
    if Enum.all?(segments, &match?({:literal, _}, &1)) do
      []
    else
      [invalid_guard_error("string interpolation", meta, env)]
    end
  end

  defp guard_safety_errors(%AST.FieldAccess{subject: subject}, env) do
    guard_safety_errors(subject, env)
  end

  defp guard_safety_errors(%AST.BinaryOp{op: op, left: left, right: right}, env)
       when op in @guard_safe_binary_ops do
    guard_safety_errors(left, env) ++ guard_safety_errors(right, env)
  end

  defp guard_safety_errors(%AST.BinaryOp{op: :/, meta: meta}, env) do
    [invalid_guard_error("division", meta, env)]
  end

  defp guard_safety_errors(%AST.UnaryOp{op: op, operand: operand}, env)
       when op in @guard_safe_unary_ops do
    guard_safety_errors(operand, env)
  end

  defp guard_safety_errors(%AST.Call{meta: meta}, env) do
    [invalid_guard_error("a function or effect call", meta, env)]
  end

  defp guard_safety_errors(expr, env) do
    [invalid_guard_error(describe_guard_expr(expr), guard_meta(expr), env)]
  end

  defp invalid_guard_error(what, meta, env) do
    %Error{
      code: "E0027",
      severity: :error,
      message: "Invalid guard expression: #{what} is not allowed in a match guard",
      location: location_from_meta(meta, env.file),
      fix_hint:
        "Guards allow literals, bindings, field access, comparisons, " <>
          "boolean operators, and +/-/* arithmetic. Compute the value in a " <>
          "'let' before the match and reference the binding in the guard",
      fix_code: nil
    }
  end

  defp describe_guard_expr(%AST.UnaryOp{op: :unwrap}), do: "'!' unwrapping"
  defp describe_guard_expr(%AST.UnaryOp{op: :propagate}), do: "'?' propagation"
  defp describe_guard_expr(%AST.Match{}), do: "a match expression"
  defp describe_guard_expr(%AST.Block{}), do: "a block"

  defp describe_guard_expr(%struct{}) do
    "a #{struct |> Module.split() |> List.last()} expression"
  end

  defp describe_guard_expr(_), do: "this expression"

  defp guard_meta(%{meta: meta}) when is_map(meta), do: meta
  defp guard_meta(_), do: %{line: 0, col: 0}

  defp bind_pattern(%AST.Identifier{name: name}, subject_type, env) do
    %{env | variables: Map.put(env.variables, name, subject_type)}
  end

  defp bind_pattern(
         %AST.Call{target: %AST.Identifier{name: "Ok"}, args: [arg]},
         subject_type,
         env
       ) do
    ok_type =
      case subject_type do
        {:result, ok_t, _err_t} -> ok_t
        _ -> :unknown
      end

    bind_pattern(arg, ok_type, env)
  end

  defp bind_pattern(
         %AST.Call{target: %AST.Identifier{name: "Err"}, args: [arg]},
         subject_type,
         env
       ) do
    err_type =
      case subject_type do
        {:result, _ok_t, err_t} -> err_t
        _ -> :unknown
      end

    bind_pattern(arg, err_type, env)
  end

  defp bind_pattern(
         %AST.Call{target: %AST.Identifier{name: variant_name}, args: args},
         subject_type,
         env
       ) do
    # Try to find enum variant and bind fields
    case subject_type do
      {:enum, enum_name} ->
        case Map.get(env.enums, enum_name) do
          %AST.EnumDecl{variants: variants} ->
            case Enum.find(variants, &(&1.name == variant_name)) do
              %AST.Variant{fields: fields} ->
                Enum.zip(args, fields)
                |> Enum.reduce(env, fn {arg, %AST.Field{type: type_ref}}, acc ->
                  bind_pattern(arg, resolve_type(type_ref, env.types), acc)
                end)

              nil ->
                Enum.reduce(args, env, fn arg, acc -> bind_pattern(arg, :unknown, acc) end)
            end

          _ ->
            Enum.reduce(args, env, fn arg, acc -> bind_pattern(arg, :unknown, acc) end)
        end

      _ ->
        Enum.reduce(args, env, fn arg, acc -> bind_pattern(arg, :unknown, acc) end)
    end
  end

  defp bind_pattern(%AST.Call{args: args}, _subject_type, env) do
    Enum.reduce(args, env, fn arg, acc -> bind_pattern(arg, :unknown, acc) end)
  end

  defp bind_pattern(_, _subject_type, env), do: env

  # ------------------------------------------------------------------
  # Match exhaustiveness checking
  # ------------------------------------------------------------------

  defp check_exhaustiveness(:bool, arms, meta, env) do
    # A guarded arm only matches when its guard passes, so it never counts
    # as covering its pattern.
    patterns = arms |> Enum.reject(& &1.guard) |> Enum.map(& &1.pattern)
    has_wildcard = Enum.any?(patterns, &match?(%AST.Wildcard{}, &1))
    has_true = Enum.any?(patterns, &match?(%AST.BoolLit{value: true}, &1))
    has_false = Enum.any?(patterns, &match?(%AST.BoolLit{value: false}, &1))
    # Also check identifier patterns (catch-all)
    has_catch_all = Enum.any?(patterns, &match?(%AST.Identifier{}, &1))

    cond do
      has_wildcard or has_catch_all ->
        []

      has_true and has_false ->
        []

      not has_true ->
        [
          %Error{
            code: "E0021",
            severity: :error,
            message: "Non-exhaustive match: missing pattern 'true'",
            location: location_from_meta(meta, env.file),
            fix_hint: "Add a 'true -> ...' arm or a wildcard '_' pattern",
            fix_code: "true -> value"
          }
        ]

      not has_false ->
        [
          %Error{
            code: "E0021",
            severity: :error,
            message: "Non-exhaustive match: missing pattern 'false'",
            location: location_from_meta(meta, env.file),
            fix_hint: "Add a 'false -> ...' arm or a wildcard '_' pattern",
            fix_code: "false -> value"
          }
        ]

      true ->
        []
    end
  end

  defp check_exhaustiveness({:enum, enum_name}, arms, meta, env) do
    case Map.get(env.enums, enum_name) do
      nil ->
        []

      %AST.EnumDecl{variants: variants} ->
        variant_names = MapSet.new(variants, & &1.name)
        # Guarded arms are partial: they don't cover their variant.
        unguarded_arms = Enum.reject(arms, & &1.guard)
        patterns = Enum.map(unguarded_arms, & &1.pattern)

        has_wildcard =
          Enum.any?(patterns, fn
            %AST.Wildcard{} ->
              true

            %AST.Identifier{name: name} ->
              not MapSet.member?(variant_names, strip_enum_prefix(name, enum_name))

            _ ->
              false
          end)

        if has_wildcard do
          []
        else
          covered =
            patterns
            |> Enum.flat_map(fn
              %AST.Identifier{name: name} ->
                [strip_enum_prefix(name, enum_name)]

              %AST.Call{target: %AST.Identifier{name: name}} ->
                [strip_enum_prefix(name, enum_name)]

              _ ->
                []
            end)
            |> MapSet.new()

          missing = MapSet.difference(variant_names, covered)

          missing_warnings =
            if MapSet.size(missing) == 0 do
              []
            else
              missing_list = missing |> MapSet.to_list() |> Enum.join(", ")

              [
                %Error{
                  code: "E0024",
                  severity: :error,
                  message:
                    "Non-exhaustive match on #{enum_name}: missing pattern(s) #{missing_list}",
                  location: location_from_meta(meta, env.file),
                  fix_hint: "Add arms for #{missing_list} or a wildcard '_' pattern",
                  fix_code: missing |> MapSet.to_list() |> Enum.map_join("\n", &"#{&1} -> value")
                }
              ]
            end

          missing_warnings ++ value_level_warnings(enum_name, unguarded_arms, env)
        end
    end
  end

  # Result is a closed two-case type: a match must cover Ok AND Err (or a
  # wildcard/binding catch-all), else it's a non-exhaustive-match error (#261).
  defp check_exhaustiveness({:result, _ok, _err}, arms, meta, env) do
    closed_match_errors(arms, meta, env, "Result",
      ok: &ok_pattern?/1,
      ok_missing: "Ok(_)",
      err: &err_pattern?/1,
      err_missing: "Err(_)"
    )
  end

  # Option is a closed two-case type: a match must cover Some AND None (or a
  # wildcard/binding catch-all), else it's a non-exhaustive-match error (#261).
  defp check_exhaustiveness({:option, _inner}, arms, meta, env) do
    closed_match_errors(arms, meta, env, "Option",
      ok: &some_pattern?/1,
      ok_missing: "Some(_)",
      err: &none_pattern?/1,
      err_missing: "None"
    )
  end

  # For non-bool/non-enum subjects, we can't check exhaustiveness
  # unless there's a wildcard
  defp check_exhaustiveness(_subject_type, arms, _meta, _env) do
    patterns = arms |> Enum.reject(& &1.guard) |> Enum.map(& &1.pattern)

    has_wildcard =
      Enum.any?(patterns, fn
        %AST.Wildcard{} -> true
        %AST.Identifier{} -> true
        _ -> false
      end)

    if has_wildcard do
      []
    else
      # We can't check exhaustiveness for Int, String, etc.
      # without a wildcard, but we also can't know it's non-exhaustive
      # (e.g., matching specific ints). Skip for now.
      []
    end
  end

  # Shared exhaustiveness check for the two closed two-case types (Result, Option).
  # A wildcard or a lowercase binding pattern covers everything; otherwise both
  # cases must be present.
  defp closed_match_errors(arms, meta, env, type_name, opts) do
    patterns = arms |> Enum.reject(& &1.guard) |> Enum.map(& &1.pattern)

    if catch_all_pattern?(patterns) do
      []
    else
      missing =
        []
        |> then(fn acc ->
          if Enum.any?(patterns, opts[:ok]), do: acc, else: acc ++ [opts[:ok_missing]]
        end)
        |> then(fn acc ->
          if Enum.any?(patterns, opts[:err]), do: acc, else: acc ++ [opts[:err_missing]]
        end)

      case missing do
        [] ->
          []

        cases ->
          missing_list = Enum.join(cases, ", ")

          [
            %Error{
              code: "E0024",
              severity: :error,
              message: "Non-exhaustive match on #{type_name}: missing pattern(s) #{missing_list}",
              location: location_from_meta(meta, env.file),
              fix_hint: "Add arms for #{missing_list} or a wildcard '_' pattern",
              fix_code: Enum.map_join(cases, "\n", &"#{&1} -> value")
            }
          ]
      end
    end
  end

  # A wildcard `_` or a lowercase binding identifier covers all remaining cases.
  # An uppercase identifier (e.g. `None`) is a variant pattern, not a catch-all.
  defp catch_all_pattern?(patterns) do
    Enum.any?(patterns, fn
      %AST.Wildcard{} -> true
      %AST.Identifier{name: name} -> not String.match?(name, ~r/^[A-Z]/)
      _ -> false
    end)
  end

  defp ok_pattern?(%AST.Call{target: %AST.Identifier{name: "Ok"}}), do: true
  defp ok_pattern?(_), do: false

  defp err_pattern?(%AST.Call{target: %AST.Identifier{name: "Err"}}), do: true
  defp err_pattern?(_), do: false

  defp some_pattern?(%AST.Call{target: %AST.Identifier{name: "Some"}}), do: true
  defp some_pattern?(_), do: false

  defp none_pattern?(%AST.Identifier{name: "None"}), do: true
  defp none_pattern?(%AST.Call{target: %AST.Identifier{name: "None"}}), do: true
  defp none_pattern?(_), do: false

  # Enum-typed fn params resolve as {:user_type, name}; declared enum
  # names are enum subjects for exhaustiveness purposes.
  defp normalize_match_subject_type({:user_type, name}, env) do
    if Map.has_key?(env.enums, name), do: {:enum, name}, else: {:user_type, name}
  end

  defp normalize_match_subject_type(subject_type, _env), do: subject_type

  # Patterns may name variants with the enum prefix (Event.Charge) or bare
  # (Charge); coverage is computed on the bare variant name.
  defp strip_enum_prefix(name, enum_name) do
    prefix = enum_name <> "."

    if String.starts_with?(name, prefix) do
      binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix))
    else
      name
    end
  end

  # Value-level exhaustiveness (W0004): a variant arm with literal field
  # patterns only covers those specific values — without a wildcard arm or
  # an all-bindings arm for the same variant, other values of that variant
  # raise case_clause at runtime. Only called when no wildcard arm exists.
  defp value_level_warnings(enum_name, arms, env) do
    arms
    |> Enum.filter(&match?(%AST.MatchArm{pattern: %AST.Call{target: %AST.Identifier{}}}, &1))
    |> Enum.group_by(fn %AST.MatchArm{
                          pattern: %AST.Call{target: %AST.Identifier{name: name}}
                        } ->
      strip_enum_prefix(name, enum_name)
    end)
    |> Enum.sort_by(fn {variant, _arms} -> variant end)
    |> Enum.flat_map(fn {variant, variant_arms} ->
      generally_covered =
        Enum.any?(variant_arms, fn %AST.MatchArm{pattern: %AST.Call{args: args}} ->
          Enum.all?(args, &binding_pattern?/1)
        end)

      literal_arm =
        Enum.find(variant_arms, fn %AST.MatchArm{pattern: %AST.Call{args: args}} ->
          Enum.any?(args, &(not binding_pattern?(&1)))
        end)

      if generally_covered or literal_arm == nil do
        []
      else
        %AST.MatchArm{
          pattern: %AST.Call{target: %AST.Identifier{name: pattern_name}, meta: pattern_meta}
        } = literal_arm

        [
          %Error{
            code: "W0004",
            severity: :warning,
            message:
              "Match on #{enum_name} covers only specific values of #{variant}: " <>
                "other #{variant}(...) values raise case_clause at runtime",
            location: location_from_meta(pattern_meta, env.file),
            fix_hint:
              "Add a '#{pattern_name}(...)' arm with variable bindings or a wildcard '_' arm",
            fix_code: "_ -> value"
          }
        ]
      end
    end)
  end

  defp binding_pattern?(%AST.Identifier{}), do: true
  defp binding_pattern?(%AST.Wildcard{}), do: true
  defp binding_pattern?(_), do: false

  # ------------------------------------------------------------------
  # Match arm type consistency
  # ------------------------------------------------------------------

  # Joins the arm types into a single result type and reports arms that cannot
  # be unified. Returns {result_type, errors}. :unknown arms are transient and
  # ignored. The join (unify_types/2) treats :unknown as the top of the lattice
  # and widens diverging inner types of same-headed compounds to :unknown;
  # genuinely different shapes (Int vs String, Result vs Int, two distinct
  # enums/user types) are :incompatible and produce an E0020.
  defp unify_arm_types(arm_types, meta, env) do
    known_types = Enum.reject(arm_types, &(&1 == :unknown))

    case known_types do
      [] ->
        {:unknown, []}

      [first | rest] ->
        Enum.reduce(rest, {first, []}, fn t, {acc_type, errors} ->
          case unify_types(acc_type, t) do
            :incompatible ->
              {acc_type,
               errors ++
                 [
                   %Error{
                     code: "E0020",
                     severity: :error,
                     message:
                       "Match arm type mismatch: expected #{format_type(acc_type)}, got #{format_type(t)}",
                     location: location_from_meta(meta, env.file),
                     fix_hint: "Ensure all match arms return the same type",
                     fix_code: "// Return #{format_type(acc_type)} from this arm"
                   }
                 ]}

            unified ->
              {unified, errors}
          end
        end)
    end
  end

  # Least-upper-bound of two inferred types for arm/branch unification. Returns
  # a unified type or :incompatible. :unknown is the top; same-headed compounds
  # recurse, widening incompatible components to :unknown rather than failing.
  defp unify_types(t, t), do: t
  defp unify_types(:unknown, t), do: t
  defp unify_types(t, :unknown), do: t
  defp unify_types({:list, a}, {:list, b}), do: {:list, unify_or_unknown(a, b)}
  defp unify_types({:set, a}, {:set, b}), do: {:set, unify_or_unknown(a, b)}
  defp unify_types({:option, a}, {:option, b}), do: {:option, unify_or_unknown(a, b)}

  defp unify_types({:result, a1, b1}, {:result, a2, b2}),
    do: {:result, unify_or_unknown(a1, a2), unify_or_unknown(b1, b2)}

  defp unify_types({:map, k1, v1}, {:map, k2, v2}),
    do: {:map, unify_or_unknown(k1, k2), unify_or_unknown(v1, v2)}

  defp unify_types(_, _), do: :incompatible

  defp unify_or_unknown(a, b) do
    case unify_types(a, b) do
      :incompatible -> :unknown
      unified -> unified
    end
  end

  # ------------------------------------------------------------------
  # Interpolation checking
  # ------------------------------------------------------------------

  # Scope check for interpolation references (segments are AST nodes,
  # normalized by the parser). Uppercase roots are skipped here: the
  # check_interpolation_shapes pass owns that rejection, so it fires
  # uniformly for bodies this type-inference pass never visits (agent
  # handlers, test blocks).
  defp check_interpolation(%AST.Identifier{name: name, meta: meta}, env) do
    cond do
      String.match?(name, ~r/^[A-Z]/) ->
        []

      Map.has_key?(env.variables, name) or Map.has_key?(env.functions, name) ->
        []

      true ->
        [
          %Error{
            code: "E0010",
            severity: :error,
            message: "Unknown identifier '#{name}' in string interpolation",
            location: location_from_meta(meta, env.file),
            fix_hint: "Did you mean to declare this variable?",
            fix_code: "let #{name} = value"
          }
        ]
    end
  end

  defp check_interpolation(%AST.FieldAccess{subject: subject}, env) do
    check_interpolation(subject, env)
  end

  # ------------------------------------------------------------------
  # Type compatibility
  # ------------------------------------------------------------------

  defp types_compatible?(:unknown, _), do: true
  defp types_compatible?(_, :unknown), do: true
  defp types_compatible?(a, a), do: true

  # Parameterized types — recurse into inner types
  defp types_compatible?({:list, a}, {:list, b}), do: types_compatible?(a, b)
  defp types_compatible?({:set, a}, {:set, b}), do: types_compatible?(a, b)
  defp types_compatible?({:option, a}, {:option, b}), do: types_compatible?(a, b)

  defp types_compatible?({:result, a1, a2}, {:result, b1, b2}),
    do: types_compatible?(a1, b1) and types_compatible?(a2, b2)

  defp types_compatible?({:map, k1, v1}, {:map, k2, v2}),
    do: types_compatible?(k1, k2) and types_compatible?(v1, v2)

  # Records are constructed as map literals (spec §8: `Ok({ id: r.body.id, ...})`),
  # so a structural map is compatible with a user type. This is NOT the deleted
  # "user_type compatible with anything" hole — it is strictly map ~ user_type,
  # the record-construction path. Field-level checking of the map against the
  # record's declared fields is deferred inference (issue #253), not #259.
  defp types_compatible?({:map, _, _}, {:user_type, _}), do: true
  defp types_compatible?({:user_type, _}, {:map, _, _}), do: true

  # Variance is INVARIANT for 1.0 (issue #259): a named type is compatible only
  # with itself. `User` ~ `User`, `Status` ~ `Status` — both handled by the
  # `a, a` clause above. Crucially there is NO "user_type/enum compatible with
  # anything" escape hatch: that hole let every ill-typed program touching a
  # user type, enum, list literal, or Ok/Err slip through. :unknown remains the
  # only permissive type, and only because it is a transient inference marker
  # (see check_function / the public-boundary :unknown guard).
  defp types_compatible?(_, _), do: false

  # ------------------------------------------------------------------
  # Pass 3: Capability checking
  # ------------------------------------------------------------------

  defp check_capabilities(declarations, env) do
    # Check for duplicate short tool names across all tool.use capabilities,
    # and duplicate declarations of single-label (scoped) capability kinds
    dup_errors =
      check_duplicate_tool_short_names(env) ++
        check_duplicate_scoped_capabilities(env)

    fn_errors =
      declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Enum.flat_map(&collect_effect_calls(&1.body, env))

    handler_errors =
      declarations
      |> Enum.filter(&match?(%AST.Handler{}, &1))
      |> Enum.flat_map(&collect_effect_calls(&1.body, env))

    dup_errors ++ fn_errors ++ handler_errors
  end

  # Walk the AST to find effect calls and check them against declared capabilities
  defp collect_effect_calls(%AST.Block{expressions: exprs}, env) do
    Enum.flat_map(exprs, &collect_effect_calls(&1, env))
  end

  # Store effect: store.<table>.<method>(...)
  # This is a three-level field access: Call(FieldAccess(FieldAccess(store, table), method), args)
  defp collect_effect_calls(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.FieldAccess{
               subject: %AST.Identifier{name: "store"},
               field: table_name
             },
             field: method
           },
           args: args,
           meta: meta
         },
         env
       )
       when method in @store_methods do
    check_store_capability(table_name, method, meta, env) ++
      Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  # Tool effect with identifier first arg: tool.call(ToolName, args) / tool.schema(ToolName)
  # Check that the specific tool name is declared in capability tool.use params.
  defp collect_effect_calls(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "tool"},
             field: method
           },
           args: [first_arg | _] = args,
           meta: meta
         },
         env
       )
       when method in ["call", "schema"] do
    tool_name = extract_tool_name_from_expr(first_arg)

    own =
      if tool_name do
        check_tool_capability(tool_name, method, meta, env)
      else
        # Non-identifier first arg (e.g. variable) — fall back to generic check
        check_effect_capability("tool", method, meta, env)
      end

    own ++ Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  defp collect_effect_calls(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: namespace},
             field: method
           },
           args: args,
           meta: meta
         } = _call,
         env
       ) do
    own =
      if effect_namespace?(namespace) and effect_method?(namespace, method) do
        check_effect_capability(namespace, method, meta, env)
      else
        []
      end

    own ++ Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  defp collect_effect_calls(%AST.Call{args: args}, env) do
    Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  defp collect_effect_calls(%AST.Let{value: value}, env) do
    collect_effect_calls(value, env)
  end

  defp collect_effect_calls(%AST.Match{subject: subject, arms: arms}, env) do
    subject_errors = collect_effect_calls(subject, env)

    arm_errors =
      Enum.flat_map(arms, fn %AST.MatchArm{body: body} ->
        collect_effect_calls(body, env)
      end)

    subject_errors ++ arm_errors
  end

  defp collect_effect_calls(%AST.Pipe{left: left, right: right}, env) do
    collect_effect_calls(left, env) ++ collect_effect_calls(right, env)
  end

  defp collect_effect_calls(%AST.BinaryOp{left: left, right: right}, env) do
    collect_effect_calls(left, env) ++ collect_effect_calls(right, env)
  end

  defp collect_effect_calls(%AST.MapLit{entries: entries}, env) do
    Enum.flat_map(entries, fn {_key, value} -> collect_effect_calls(value, env) end)
  end

  defp collect_effect_calls(%AST.RecordLit{fields: fields}, env) do
    Enum.flat_map(fields, fn {_key, value} -> collect_effect_calls(value, env) end)
  end

  defp collect_effect_calls(%AST.ListLit{elements: elements}, env) do
    Enum.flat_map(elements, &collect_effect_calls(&1, env))
  end

  defp collect_effect_calls(%AST.UnaryOp{operand: operand}, env) do
    collect_effect_calls(operand, env)
  end

  defp collect_effect_calls(_expr, _env), do: []

  @doc false
  def effect_namespace?(namespace), do: Map.has_key?(@effect_namespaces, namespace)

  @doc false
  def effect_method?(namespace, method) do
    case Map.get(@effect_methods, namespace) do
      nil -> false
      methods -> method in methods
    end
  end

  defp check_effect_capability(namespace, _method, meta, env) do
    case Map.fetch!(@effect_namespaces, namespace) do
      # No capability required for this effect namespace (e.g., trace)
      nil ->
        []

      required_capability ->
        check_effect_capability_required(namespace, required_capability, meta, env)
    end
  end

  defp check_effect_capability_required(namespace, required_capability, meta, env) do
    has_capability =
      Enum.any?(env.capabilities, fn %AST.Capability{kind: kind} ->
        kind == required_capability
      end)

    if has_capability do
      []
    else
      span = capability_insertion_span(env)

      [
        %Error{
          code: "E0012",
          severity: :error,
          message:
            "Capability '#{required_capability}' required but not declared. " <>
              "Effect calls to '#{namespace}' require this capability.",
          location: location_from_meta(meta, env.file),
          fix_hint:
            "Add a capability declaration to the module: capability #{required_capability}",
          fix_code: "capability #{required_capability}",
          span: span,
          edit_kind: if(span, do: :insert_line)
        }
      ]
    end
  end

  # ------------------------------------------------------------------
  # Store capability checking
  # ------------------------------------------------------------------

  defp check_store_capability(table_name, _method, meta, env) do
    has_capability =
      Enum.any?(env.capabilities, fn %AST.Capability{kind: kind, params: params} ->
        kind == "store.table" and
          Enum.any?(params, fn
            %AST.StringLit{segments: [{:literal, name}]} -> name == table_name
            _ -> false
          end)
      end)

    if has_capability do
      []
    else
      span = capability_insertion_span(env)

      [
        %Error{
          code: "E0012",
          severity: :error,
          message:
            "Capability 'store.table(\"#{table_name}\")' required but not declared. " <>
              "Store operations on '#{table_name}' require this capability.",
          location: location_from_meta(meta, env.file),
          fix_hint:
            "Add a capability declaration to the module: capability store.table(\"#{table_name}\")",
          fix_code: "capability store.table(\"#{table_name}\")",
          span: span,
          edit_kind: if(span, do: :insert_line)
        }
      ]
    end
  end

  # ------------------------------------------------------------------
  # Tool capability checking — identifier-based tool references
  # ------------------------------------------------------------------

  # Extract a tool name string from an AST expression.
  # The parser produces ToolRef nodes for tool references in tool.call/tool.schema
  # and capability tool.use params. StringLit is supported for backward compatibility.
  @doc false
  def extract_tool_name_from_expr(%AST.ToolRef{name: name}), do: name
  def extract_tool_name_from_expr(%AST.StringLit{segments: [{:literal, name}]}), do: name
  def extract_tool_name_from_expr(_), do: nil

  # Extract a tool name from a capability param expression.
  @doc false
  def extract_tool_name_from_param(%AST.ToolRef{name: name}), do: name
  def extract_tool_name_from_param(%AST.StringLit{segments: [{:literal, name}]}), do: name
  def extract_tool_name_from_param(_), do: nil

  # Get the short (unqualified) name of a tool, e.g. "CreateRefund" from "Stripe.CreateRefund"
  defp tool_short_name(name) do
    case String.split(name, ".") do
      [short] -> short
      parts -> List.last(parts)
    end
  end

  # Collect all declared tool names from tool.use capabilities in env
  defp collect_declared_tool_names(env) do
    env.capabilities
    |> Enum.filter(&match?(%AST.Capability{kind: "tool.use"}, &1))
    |> Enum.flat_map(fn %AST.Capability{params: params} ->
      params
      |> Enum.map(&extract_tool_name_from_param/1)
      |> Enum.reject(&is_nil/1)
    end)
  end

  # Check that a tool.call/tool.schema references a tool declared in capability tool.use params
  defp check_tool_capability(tool_name, _method, meta, env) do
    declared_names = collect_declared_tool_names(env)

    span = capability_insertion_span(env)

    cond do
      declared_names == [] ->
        # No tool.use capability at all — produce E0012
        [
          %Error{
            code: "E0012",
            severity: :error,
            message:
              "Capability 'tool.use' required but not declared. " <>
                "Effect calls to 'tool' require this capability.",
            location: location_from_meta(meta, env.file),
            fix_hint:
              "Add a capability declaration to the module: capability tool.use(#{tool_name})",
            fix_code: "capability tool.use(#{tool_name})",
            span: span,
            edit_kind: if(span, do: :insert_line)
          }
        ]

      tool_name in declared_names ->
        # Exact match found
        []

      true ->
        # Has tool.use but this specific tool is not listed — E0014
        [
          %Error{
            code: "E0014",
            severity: :error,
            message:
              "Tool '#{tool_name}' is not declared in any capability tool.use. " <>
                "Declared tools: #{Enum.join(declared_names, ", ")}.",
            location: location_from_meta(meta, env.file),
            fix_hint:
              "Add '#{tool_name}' to your capability declaration: capability tool.use(#{tool_name})",
            fix_code: "capability tool.use(#{tool_name})",
            span: span,
            edit_kind: if(span, do: :insert_line)
          }
        ]
    end
  end

  # Check that no two tool.use params produce the same short name
  defp check_duplicate_tool_short_names(env) do
    declared_names = collect_declared_tool_names(env)

    # Group by short name and find duplicates
    declared_names
    |> Enum.group_by(&tool_short_name/1)
    |> Enum.flat_map(fn {short_name, full_names} ->
      if length(full_names) > 1 do
        # Find a capability meta to attach the error to
        cap_meta =
          env.capabilities
          |> Enum.filter(&match?(%AST.Capability{kind: "tool.use"}, &1))
          |> List.first()
          |> then(fn
            %AST.Capability{meta: meta} -> meta
            _ -> %{line: 1, col: 1, file: env.file}
          end)

        [
          %Error{
            code: "E0015",
            severity: :error,
            message:
              "Duplicate short tool name '#{short_name}'. " <>
                "The following tools share the same short name: #{Enum.join(full_names, ", ")}. " <>
                "Tool names must be unique within a module.",
            location: location_from_meta(cap_meta, env.file),
            fix_hint: "Rename one of the tools to avoid the naming conflict",
            fix_code: "// Rename one of: #{Enum.join(full_names, ", ")}"
          }
        ]
      else
        []
      end
    end)
  end

  # Scoped (single-label) capability kinds: the parameter names a scope
  # label — a memory namespace, event stream, process pool, or timer group
  # — that the compiler threads into every generated runtime call (spec
  # §3.2). Two declarations of the same kind in one scope would make that
  # label ambiguous, so each module or agent may declare at most one.
  @scoped_capability_kinds ["memory.kv", "event.log", "process.spawn", "timer"]

  defp check_duplicate_scoped_capabilities(env) do
    # A nested agent's env merges the enclosing module's capabilities;
    # only the scope's own declarations count toward the duplicate rule
    # (the agent's label overrides the module's for calls inside it).
    env
    |> Map.get(:own_capabilities, env.capabilities)
    |> Enum.filter(fn %AST.Capability{kind: kind} -> kind in @scoped_capability_kinds end)
    |> Enum.group_by(fn %AST.Capability{kind: kind} -> kind end)
    |> Enum.flat_map(fn
      {_kind, [_single]} ->
        []

      {kind, [first | rest]} ->
        first_label = scoped_capability_label(first)

        Enum.map(rest, fn cap ->
          %Error{
            code: "E0017",
            severity: :error,
            message:
              "Duplicate '#{kind}' capability: #{scoped_capability_label(cap)}. " <>
                "This module already declares #{kind}(#{inspect(first_label)}) — " <>
                "the parameter names the scope label for every #{kind} call, " <>
                "so at most one #{kind} capability is allowed per module or agent.",
            location: location_from_meta(cap.meta, env.file),
            fix_hint:
              "Remove this declaration or merge its uses into " <>
                "#{kind}(#{inspect(first_label)})",
            fix_code: "// Remove: capability #{kind}(#{inspect(scoped_capability_label(cap))})"
          }
        end)
    end)
  end

  defp scoped_capability_label(%AST.Capability{params: []}), do: ""

  defp scoped_capability_label(%AST.Capability{params: [param | _]}) do
    case param do
      %AST.StringLit{segments: [{:literal, text}]} -> text
      %AST.StringLit{segments: []} -> ""
      %AST.Identifier{name: name} -> name
      _ -> ""
    end
  end

  # ------------------------------------------------------------------
  # Agent environment
  # ------------------------------------------------------------------

  defp build_agent_env(%AST.Agent{
         name: agent_name,
         capabilities: capabilities,
         state: state,
         phases: phases,
         fns: fns,
         meta: meta
       }) do
    file = Map.get(meta, :file, "unknown")

    types = Map.new(@builtin_type_names, fn name -> {name, :builtin} end)

    types =
      types
      |> Map.put("Option", :builtin_param)
      |> Map.put("Result", :builtin_param)
      |> Map.put("List", :builtin_param)
      |> Map.put("Map", :builtin_param)
      |> Map.put("Set", :builtin_param)

    # Register Phase enum as a type if it exists
    enums =
      if phases do
        %{"Phase" => phases}
      else
        %{}
      end

    types =
      Enum.reduce(enums, types, fn {name, _}, acc -> Map.put(acc, name, :enum) end)

    # Register functions
    functions =
      fns
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Map.new(fn %AST.Fn{name: name, params: params, return_type: ret} ->
        {name, %{params: params, return_type: resolve_type(ret, types)}}
      end)

    # Build state variables
    variables =
      state
      |> Enum.map(fn %AST.Field{name: name, type: type} ->
        {name, resolve_type(type, types)}
      end)
      |> Map.new()

    %{
      module_name: agent_name,
      types: types,
      enums: enums,
      functions: functions,
      variables: variables,
      capabilities: capabilities,
      tool_error_names: [],
      current_fn_return_type: nil,
      file: file,
      decl_meta: meta
    }
  end

  # Env for an agent nested inside a module: the agent's own env enriched
  # with the enclosing module's types, enums, capabilities, and tool error
  # names. The agent's own declarations win on name collisions (e.g. Phase).
  defp build_nested_agent_env(%AST.Agent{} = agent, module_env) do
    agent_env = build_agent_env(agent)

    # A capability declared at both module and agent level (e.g. the same
    # tool.use) is one grant, not a duplicate — dedup structurally so the
    # duplicate-tool-name check doesn't fire across the two scopes.
    merged_capabilities =
      Enum.uniq_by(
        agent_env.capabilities ++ module_env.capabilities,
        &capability_dedup_key/1
      )

    %{
      agent_env
      | types: Map.merge(module_env.types, agent_env.types),
        enums: Map.merge(module_env.enums, agent_env.enums),
        capabilities: merged_capabilities,
        tool_error_names: module_env.tool_error_names,
        file: module_env.file
    }
    |> Map.put(:own_capabilities, agent_env.capabilities)
    |> Map.put(:source_lines, Map.get(module_env, :source_lines))
  end

  defp capability_dedup_key(%AST.Capability{kind: kind, params: params}) do
    {kind, Enum.map(params, &capability_param_fingerprint/1)}
  end

  # Fingerprints must be position-independent: interpolation segments are
  # AST nodes carrying meta, so strip down to the referenced names.
  defp capability_param_fingerprint(%AST.StringLit{segments: segments}) do
    {:string,
     Enum.map(segments, fn
       {:literal, text} -> {:literal, text}
       {:interpolation, expr} -> {:interpolation, capability_param_fingerprint(expr)}
     end)}
  end

  defp capability_param_fingerprint(%AST.Identifier{name: name}), do: {:ident, name}
  defp capability_param_fingerprint(%AST.ToolRef{name: name}), do: {:tool, name}

  defp capability_param_fingerprint(%AST.FieldAccess{subject: subject, field: field}),
    do: {:field, capability_param_fingerprint(subject), field}

  defp capability_param_fingerprint(other), do: other

  # ------------------------------------------------------------------
  # Agent state validation
  # ------------------------------------------------------------------

  defp validate_agent_state(state_fields, env) do
    Enum.flat_map(state_fields, fn %AST.Field{type: type} ->
      validate_type_ref(type, env)
    end)
  end

  # ------------------------------------------------------------------
  # Phase transition validation
  # ------------------------------------------------------------------

  defp validate_phase_transitions(%AST.Agent{phases: nil}, _env), do: []

  defp validate_phase_transitions(
         %AST.Agent{phases: %AST.EnumDecl{variants: variants}, meta: meta},
         env
       ) do
    variant_names = MapSet.new(variants, & &1.name)

    # Check that all transition targets exist as phase variants
    Enum.flat_map(variants, fn %AST.Variant{name: source, transitions: targets, meta: vmeta} ->
      Enum.flat_map(targets, fn target ->
        if MapSet.member?(variant_names, target) do
          []
        else
          [
            %Error{
              code: "E0030",
              severity: :error,
              message:
                "Invalid phase transition: '#{source}' declares transition to unknown phase '#{target}'",
              location: location_from_meta(vmeta, env.file),
              fix_hint: "Add '#{target}' as a Phase variant or remove the transition",
              fix_code: "#{target} -> []"
            }
          ]
        end
      end)
    end) ++ check_unreachable_phases(variants, meta, env)
  end

  defp check_unreachable_phases(variants, meta, env) do
    # Find all phases that are transition targets (reachable)
    all_targets =
      variants
      |> Enum.flat_map(& &1.transitions)
      |> MapSet.new()

    # The first variant is implicitly reachable (it's the start phase)
    first_variant =
      case variants do
        [first | _] -> first.name
        [] -> nil
      end

    Enum.flat_map(variants, fn %AST.Variant{name: name} ->
      if name == first_variant or MapSet.member?(all_targets, name) do
        []
      else
        [
          %Error{
            code: "E0031",
            severity: :warning,
            message: "Phase '#{name}' is unreachable — no transitions lead to it",
            location: location_from_meta(meta, env.file),
            fix_hint: "Add a transition to '#{name}' from another phase or remove it",
            fix_code: "SomePhase -> [#{name}]"
          }
        ]
      end
    end)
  end

  # ------------------------------------------------------------------
  # Phase handler checking
  # ------------------------------------------------------------------

  defp check_phase_handlers(%AST.Agent{phases: nil}, _env), do: []

  defp check_phase_handlers(
         %AST.Agent{phases: %AST.EnumDecl{variants: variants}, handlers: handlers, meta: meta},
         env
       ) do
    # Collect all phase handler references
    handled_phases =
      handlers
      |> Enum.filter(fn %AST.AgentHandler{kind: kind} -> kind == :phase end)
      |> Enum.map(fn %AST.AgentHandler{phase: phase} -> phase end)
      |> MapSet.new()

    # Every phase variant needs a handler
    Enum.flat_map(variants, fn %AST.Variant{name: name} ->
      if MapSet.member?(handled_phases, name) do
        []
      else
        [
          %Error{
            code: "E0032",
            severity: :error,
            message: "Phase '#{name}' has no handler — add 'on phase(Phase.#{name}) -> { ... }'",
            location: location_from_meta(meta, env.file),
            fix_hint: "Add a handler for this phase",
            fix_code: "on phase(Phase.#{name}) -> { ... }"
          }
        ]
      end
    end)
  end

  # ------------------------------------------------------------------
  # Transition call validation
  # ------------------------------------------------------------------

  defp validate_transition_calls(%AST.Agent{phases: nil, handlers: handlers}, env) do
    # If there are no phases but there are transition calls, that's an error
    transitions = collect_transitions_from_handlers(handlers)

    Enum.map(transitions, fn {_phase, tmeta} ->
      %Error{
        code: "E0033",
        severity: :error,
        message: "transition() used but no Phase enum is defined in this agent",
        location: location_from_meta(tmeta, env.file),
        fix_hint: "Define an 'enum Phase { ... }' in the agent",
        fix_code: "enum Phase { Start -> [] }"
      }
    end)
  end

  defp validate_transition_calls(
         %AST.Agent{phases: %AST.EnumDecl{variants: variants}, handlers: handlers},
         env
       ) do
    # Build transition map: source_phase -> allowed_targets
    transition_map =
      Map.new(variants, fn %AST.Variant{name: name, transitions: targets} ->
        {name, MapSet.new(targets)}
      end)

    variant_names = MapSet.new(variants, & &1.name)

    # Check each handler's transition calls
    Enum.flat_map(handlers, fn handler ->
      source_phase =
        case handler do
          %AST.AgentHandler{kind: :start} -> :start
          %AST.AgentHandler{kind: :phase, phase: phase} -> phase
        end

      transitions = collect_transitions_from_body(handler.body)

      Enum.flat_map(transitions, fn {target_phase, tmeta} ->
        cond do
          not MapSet.member?(variant_names, target_phase) ->
            [
              %Error{
                code: "E0030",
                severity: :error,
                message: "Transition to unknown phase '#{target_phase}'",
                location: location_from_meta(tmeta, env.file),
                fix_hint: "Use a valid Phase variant name",
                fix_code:
                  "transition(Phase.#{closest_name(target_phase, MapSet.to_list(variant_names))})"
              }
            ]

          source_phase == :start ->
            # Start handler can transition to any phase
            []

          true ->
            allowed = Map.get(transition_map, source_phase, MapSet.new())

            if MapSet.member?(allowed, target_phase) do
              []
            else
              allowed_list = allowed |> MapSet.to_list() |> Enum.join(", ")

              [
                %Error{
                  code: "E0030",
                  severity: :error,
                  message:
                    "Invalid transition: Phase.#{source_phase} cannot transition to Phase.#{target_phase}. Allowed targets: [#{allowed_list}]",
                  location: location_from_meta(tmeta, env.file),
                  fix_hint:
                    "Update the Phase enum to allow this transition or use an allowed target",
                  fix_code: "#{source_phase} -> [#{allowed_list}, #{target_phase}]"
                }
              ]
            end
        end
      end)
    end)
  end

  defp collect_transitions_from_handlers(handlers) do
    Enum.flat_map(handlers, fn handler ->
      collect_transitions_from_body(handler.body)
    end)
  end

  defp collect_transitions_from_body(%AST.Block{expressions: exprs}) do
    Enum.flat_map(exprs, &collect_transitions_from_body/1)
  end

  defp collect_transitions_from_body(%AST.Transition{phase: phase, meta: meta}) do
    [{phase, meta}]
  end

  defp collect_transitions_from_body(%AST.Match{arms: arms}) do
    Enum.flat_map(arms, fn %AST.MatchArm{body: body} ->
      collect_transitions_from_body(body)
    end)
  end

  defp collect_transitions_from_body(%AST.Let{value: value}) do
    collect_transitions_from_body(value)
  end

  defp collect_transitions_from_body(_), do: []

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp find_enum_variant(name, env) do
    result =
      Enum.find(env.enums, fn {_enum_name, %AST.EnumDecl{variants: variants}} ->
        Enum.any?(variants, &(&1.name == name))
      end)

    case result do
      {enum_name, _} -> {:ok, enum_name}
      nil -> :error
    end
  end

  defp format_type(:int), do: "Int"
  defp format_type(:float), do: "Float"
  defp format_type(:string), do: "String"
  defp format_type(:bool), do: "Bool"
  defp format_type(:uuid), do: "Uuid"
  defp format_type(:instant), do: "Instant"
  defp format_type(:duration), do: "Duration"
  defp format_type(:email), do: "Email"
  defp format_type(:url), do: "Url"
  defp format_type({:option, inner}), do: "Option[#{format_type(inner)}]"
  defp format_type({:result, ok, err}), do: "Result[#{format_type(ok)}, #{format_type(err)}]"
  defp format_type({:list, elem}), do: "List[#{format_type(elem)}]"
  defp format_type({:map, k, v}), do: "Map[#{format_type(k)}, #{format_type(v)}]"
  defp format_type({:set, elem}), do: "Set[#{format_type(elem)}]"
  defp format_type({:user_type, name}), do: name
  defp format_type({:enum, name}), do: name
  defp format_type(:unknown), do: "<unknown>"
  defp format_type(other), do: inspect(other)

  defp location_from_meta(%{line: line, col: col, file: file}, _default_file) do
    %{file: file, line: line, col: col}
  end

  defp location_from_meta(%{line: line, col: col}, default_file) do
    %{file: default_file, line: line, col: col}
  end

  defp location_from_meta(_, default_file) do
    %{file: default_file, line: 0, col: 0}
  end

  # Span covering `text` at the position `meta` points to. Only safe when
  # meta locates the exact start of `text` in the source (identifier and
  # type-name metas do; call metas point at the lparen and do not).
  defp span_from_meta(%{line: line, col: col}, text)
       when is_integer(line) and line > 0 and is_integer(col) and col > 0 do
    Error.span(line, col, String.length(text))
  end

  defp span_from_meta(_, _), do: nil

  # Insertion point for a new `capability` line: directly under the last
  # declaration the module/agent already has (matching its indentation),
  # or as the first body line after the opening declaration.
  defp capability_insertion_span(env) do
    own_capabilities = Map.get(env, :own_capabilities, env.capabilities)

    positions =
      for %AST.Capability{meta: %{line: line, col: col}} <- own_capabilities,
          is_integer(line) and is_integer(col),
          do: {line, col}

    case Enum.max(positions, fn -> nil end) do
      {line, col} ->
        Error.point(line + 1, col)

      nil ->
        case Map.get(env, :decl_meta) do
          %{line: line, col: col} when is_integer(line) and is_integer(col) and line > 0 ->
            Error.point(line + 1, col + 2)

          _ ->
            nil
        end
    end
  end

  defp suggest_types(name, env) do
    known =
      env.types
      |> Map.keys()
      |> Enum.reject(&(&1 in ["Option", "Result", "List", "Map", "Set"]))
      |> Enum.sort()

    # Simple string distance suggestion
    close =
      known
      |> Enum.filter(&(String.jaro_distance(&1, name) > 0.7))
      |> Enum.take(3)

    case close do
      [] -> Enum.join(Enum.take(known, 5), ", ")
      suggestions -> Enum.join(suggestions, ", ")
    end
  end

  # ------------------------------------------------------------------
  # E0011: Duplicate definition detection
  # ------------------------------------------------------------------

  defp check_duplicate_definitions(declarations, env) do
    # Collect all named definitions with their locations
    named =
      Enum.flat_map(declarations, fn
        %AST.Fn{name: name, meta: meta} -> [{:fn, name, meta}]
        %AST.TypeDecl{name: name, meta: meta} -> [{:type, name, meta}]
        %AST.EnumDecl{name: name, meta: meta} -> [{:enum, name, meta}]
        _ -> []
      end)

    # Group by name and find duplicates
    named
    |> Enum.group_by(fn {_kind, name, _meta} -> name end)
    |> Enum.flat_map(fn {name, entries} ->
      if length(entries) > 1 do
        # Report error for each duplicate after the first
        entries
        |> Enum.drop(1)
        |> Enum.map(fn {kind, _name, meta} ->
          %Error{
            code: "E0011",
            severity: :error,
            message: "Duplicate definition: #{kind} '#{name}' is already defined in this scope",
            location: location_from_meta(meta, env.file),
            fix_hint: "Rename this #{kind} or remove the duplicate definition",
            fix_code: "// Remove or rename the duplicate #{kind} '#{name}'"
          }
        end)
      else
        []
      end
    end)
  end

  # ------------------------------------------------------------------
  # W0001: Unused binding detection
  # ------------------------------------------------------------------

  defp check_unused_bindings_in_declarations(declarations, _env) do
    fns = Enum.filter(declarations, &match?(%AST.Fn{}, &1))
    Enum.flat_map(fns, &check_unused_bindings_in_fn/1)
  end

  defp check_unused_bindings_in_fn(%AST.Fn{body: body, meta: fn_meta}) do
    # Collect all let-binding names from the body
    let_bindings = collect_let_bindings(body)
    # Collect all referenced identifiers in the body
    referenced = collect_referenced_identifiers(body)

    # Find unused bindings (ignore _ prefixed names)
    Enum.flat_map(let_bindings, fn {name, meta, name_meta} ->
      if name in referenced or String.starts_with?(name, "_") do
        []
      else
        span = span_from_meta(name_meta, name)

        [
          %Error{
            code: "W0001",
            severity: :warning,
            message: "Unused binding '#{name}'",
            location: location_from_meta(meta, Map.get(fn_meta, :file, "unknown")),
            fix_hint:
              "Remove this binding or prefix with _ to indicate it is intentionally unused",
            fix_code: "_#{name}",
            span: span,
            edit_kind: if(span, do: :replace)
          }
        ]
      end
    end)
  end

  defp collect_let_bindings(%AST.Block{expressions: exprs}) do
    Enum.flat_map(exprs, &collect_let_bindings/1)
  end

  defp collect_let_bindings(%AST.Let{name: name, meta: meta, name_meta: name_meta, value: value}) do
    [{name, meta, name_meta} | collect_let_bindings(value)]
  end

  defp collect_let_bindings(%AST.Match{arms: arms}) do
    Enum.flat_map(arms, fn %AST.MatchArm{body: body} ->
      collect_let_bindings(body)
    end)
  end

  defp collect_let_bindings(_), do: []

  defp collect_referenced_identifiers(%AST.Block{expressions: exprs}) do
    Enum.flat_map(exprs, &collect_referenced_identifiers/1)
  end

  defp collect_referenced_identifiers(%AST.Identifier{name: name}) do
    [name]
  end

  defp collect_referenced_identifiers(%AST.Let{value: value}) do
    collect_referenced_identifiers(value)
  end

  defp collect_referenced_identifiers(%AST.Call{target: target, args: args}) do
    collect_referenced_identifiers(target) ++
      Enum.flat_map(args, &collect_referenced_identifiers/1)
  end

  defp collect_referenced_identifiers(%AST.BinaryOp{left: left, right: right}) do
    collect_referenced_identifiers(left) ++ collect_referenced_identifiers(right)
  end

  defp collect_referenced_identifiers(%AST.UnaryOp{operand: operand}) do
    collect_referenced_identifiers(operand)
  end

  defp collect_referenced_identifiers(%AST.Match{subject: subject, arms: arms}) do
    collect_referenced_identifiers(subject) ++
      Enum.flat_map(arms, fn %AST.MatchArm{guard: guard, body: body} ->
        guard_refs = if guard, do: collect_referenced_identifiers(guard), else: []
        guard_refs ++ collect_referenced_identifiers(body)
      end)
  end

  defp collect_referenced_identifiers(%AST.Pipe{left: left, right: right}) do
    collect_referenced_identifiers(left) ++ collect_referenced_identifiers(right)
  end

  defp collect_referenced_identifiers(%AST.FieldAccess{subject: subject}) do
    collect_referenced_identifiers(subject)
  end

  defp collect_referenced_identifiers(%AST.ListLit{elements: elements}) do
    Enum.flat_map(elements, &collect_referenced_identifiers/1)
  end

  defp collect_referenced_identifiers(%AST.MapLit{entries: entries}) do
    Enum.flat_map(entries, fn {_key, value} -> collect_referenced_identifiers(value) end)
  end

  defp collect_referenced_identifiers(%AST.RecordLit{fields: fields}) do
    Enum.flat_map(fields, fn {_key, value} -> collect_referenced_identifiers(value) end)
  end

  defp collect_referenced_identifiers(%AST.StringLit{segments: segments}) do
    Enum.flat_map(segments, fn
      {:interpolation, expr} -> collect_referenced_identifiers(expr)
      _ -> []
    end)
  end

  defp collect_referenced_identifiers(_), do: []

  # ------------------------------------------------------------------
  # W0002: Unused capability detection
  # ------------------------------------------------------------------

  defp check_unused_capabilities(declarations, env) do
    # Collect all effect calls/handlers to determine which capabilities are exercised
    used_capabilities = collect_used_capabilities(declarations, env)

    env.capabilities
    |> Enum.flat_map(fn %AST.Capability{kind: kind, meta: meta} ->
      if kind in used_capabilities do
        []
      else
        span = span_from_meta(meta, "capability")

        [
          %Error{
            code: "W0002",
            severity: :warning,
            message: "Unused capability '#{kind}' — declared but never exercised",
            location: location_from_meta(meta, env.file),
            fix_hint: "Remove this capability declaration if it is no longer needed",
            fix_code: "",
            span: span,
            edit_kind: if(span, do: :delete_line)
          }
        ]
      end
    end)
  end

  defp collect_used_capabilities(declarations, _env) do
    # Check effect calls in function bodies
    fn_caps =
      declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Enum.flat_map(fn %AST.Fn{body: body} ->
        collect_effect_namespaces(body)
      end)
      |> Enum.map(&namespace_capability/1)
      |> Enum.reject(&is_nil/1)

    # Check handlers (they require http.in/queue.consume/schedule.trigger)
    handler_caps =
      declarations
      |> Enum.filter(&match?(%AST.Handler{}, &1))
      |> Enum.flat_map(fn %AST.Handler{source: source, body: body} ->
        cap = handler_required_capability(source)

        body_caps =
          body
          |> collect_effect_namespaces()
          |> Enum.map(&namespace_capability/1)
          |> Enum.reject(&is_nil/1)

        [cap | body_caps]
      end)
      |> Enum.reject(&is_nil/1)

    MapSet.new(fn_caps ++ handler_caps)
  end

  # store.<table>.<method> usage exercises the store.table capability; all
  # other namespaces map through the effect registry.
  defp namespace_capability("store"), do: "store.table"
  defp namespace_capability(namespace), do: Map.get(@effect_namespaces, namespace)

  defp collect_effect_namespaces(%AST.Block{expressions: exprs}) do
    Enum.flat_map(exprs, &collect_effect_namespaces/1)
  end

  # Store effect: store.<table>.<method>(...) exercises store.table
  defp collect_effect_namespaces(%AST.Call{
         target: %AST.FieldAccess{
           subject: %AST.FieldAccess{subject: %AST.Identifier{name: "store"}, field: _table},
           field: method
         },
         args: args
       })
       when method in @store_methods do
    ["store"] ++ Enum.flat_map(args, &collect_effect_namespaces/1)
  end

  defp collect_effect_namespaces(%AST.Call{
         target: %AST.FieldAccess{
           subject: %AST.Identifier{name: namespace},
           field: method
         },
         args: args
       }) do
    ns =
      if effect_namespace?(namespace) and effect_method?(namespace, method) do
        [namespace]
      else
        []
      end

    ns ++ Enum.flat_map(args, &collect_effect_namespaces/1)
  end

  defp collect_effect_namespaces(%AST.Call{args: args}) do
    Enum.flat_map(args, &collect_effect_namespaces/1)
  end

  defp collect_effect_namespaces(%AST.Let{value: value}) do
    collect_effect_namespaces(value)
  end

  defp collect_effect_namespaces(%AST.Match{subject: subject, arms: arms}) do
    collect_effect_namespaces(subject) ++
      Enum.flat_map(arms, fn %AST.MatchArm{body: body} ->
        collect_effect_namespaces(body)
      end)
  end

  defp collect_effect_namespaces(%AST.Pipe{left: left, right: right}) do
    collect_effect_namespaces(left) ++ collect_effect_namespaces(right)
  end

  defp collect_effect_namespaces(%AST.BinaryOp{left: left, right: right}) do
    collect_effect_namespaces(left) ++ collect_effect_namespaces(right)
  end

  defp collect_effect_namespaces(%AST.MapLit{entries: entries}) do
    Enum.flat_map(entries, fn {_key, value} -> collect_effect_namespaces(value) end)
  end

  defp collect_effect_namespaces(%AST.RecordLit{fields: fields}) do
    Enum.flat_map(fields, fn {_key, value} -> collect_effect_namespaces(value) end)
  end

  defp collect_effect_namespaces(%AST.ListLit{elements: elements}) do
    Enum.flat_map(elements, &collect_effect_namespaces/1)
  end

  defp collect_effect_namespaces(%AST.UnaryOp{operand: operand}) do
    collect_effect_namespaces(operand)
  end

  defp collect_effect_namespaces(_), do: []

  # ------------------------------------------------------------------
  # W0003: Unreachable code after stop()
  # ------------------------------------------------------------------

  defp check_unreachable_after_stop(declarations) do
    declarations
    |> Enum.filter(&match?(%AST.Fn{}, &1))
    |> Enum.flat_map(fn %AST.Fn{body: body, meta: fn_meta} ->
      check_block_for_unreachable(body, Map.get(fn_meta, :file, "unknown"))
    end)
  end

  defp check_block_for_unreachable(%AST.Block{expressions: exprs}, file) do
    exprs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [expr, next_expr] ->
      if is_stop_call?(expr) do
        next_meta = extract_meta(next_expr)

        [
          %Error{
            code: "W0003",
            severity: :warning,
            message: "Unreachable code after stop()",
            location: location_from_meta(next_meta, file),
            fix_hint: "Remove the code after stop() — it will never be executed",
            fix_code: ""
          }
        ]
      else
        []
      end
    end)
  end

  defp check_block_for_unreachable(_, _file), do: []

  defp is_stop_call?(%AST.Stop{}), do: true
  defp is_stop_call?(%AST.Call{target: %AST.Identifier{name: "stop"}, args: []}), do: true
  defp is_stop_call?(%AST.Suspend{}), do: true
  defp is_stop_call?(_), do: false

  defp extract_meta(%{meta: meta}), do: meta
  defp extract_meta(_), do: %{line: 0, col: 0}

  # ------------------------------------------------------------------
  # Agent-only lifecycle calls outside agent handlers:
  # E0033 transition(), E0034 suspend(), E0036 stop()
  # ------------------------------------------------------------------

  defp check_agent_only_calls(declarations, env) do
    declarations
    |> Enum.flat_map(fn
      %AST.Fn{body: body} -> collect_agent_only_calls(body)
      %AST.Handler{body: body} -> collect_agent_only_calls(body)
      _ -> []
    end)
    |> Enum.map(fn {kind, meta} -> agent_only_call_error(kind, meta, env) end)
  end

  defp agent_only_call_error(:transition, meta, env) do
    %Error{
      code: "E0033",
      severity: :error,
      message:
        "transition() can only be used in agent handlers, not in module functions or handlers",
      location: location_from_meta(meta, env.file),
      fix_hint: "Move this to an agent handler (on start/on phase) — phases only exist in agents",
      fix_code: "on phase(Phase.Name) -> { transition(Phase.Next) }"
    }
  end

  defp agent_only_call_error(:suspend, meta, env) do
    %Error{
      code: "E0034",
      severity: :error,
      message:
        "suspend() can only be used in agent handlers, not in module functions or handlers",
      location: location_from_meta(meta, env.file),
      fix_hint: "Move this to an agent handler (on start/on phase)",
      fix_code: "on phase(Phase.Name) -> { suspend(\"reason\") }"
    }
  end

  defp agent_only_call_error(:stop, meta, env) do
    %Error{
      code: "E0036",
      severity: :error,
      message: "stop() can only be used in agent handlers, not in module functions or handlers",
      location: location_from_meta(meta, env.file),
      fix_hint: "Move this to an agent handler (on start/on phase)",
      fix_code: "on phase(Phase.Name) -> { stop() }"
    }
  end

  defp collect_agent_only_calls(%AST.Transition{meta: meta}), do: [{:transition, meta}]
  defp collect_agent_only_calls(%AST.Suspend{meta: meta}), do: [{:suspend, meta}]
  defp collect_agent_only_calls(%AST.Stop{meta: meta}), do: [{:stop, meta}]

  defp collect_agent_only_calls(%AST.Block{expressions: exprs}),
    do: Enum.flat_map(exprs, &collect_agent_only_calls/1)

  defp collect_agent_only_calls(%AST.Match{arms: arms}) do
    Enum.flat_map(arms, fn %AST.MatchArm{body: body} -> collect_agent_only_calls(body) end)
  end

  defp collect_agent_only_calls(%AST.Let{value: value}), do: collect_agent_only_calls(value)
  defp collect_agent_only_calls(_), do: []

  # ------------------------------------------------------------------
  # E0035: idempotent() outside handler
  # ------------------------------------------------------------------

  defp check_idempotent_outside_handler(declarations, env) do
    # idempotent() is only valid inside handler bodies, not in regular functions
    fn_idempotents =
      declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Enum.flat_map(fn %AST.Fn{body: body} ->
        collect_idempotents(body)
      end)

    fn_idempotents
    |> Enum.map(fn meta ->
      %Error{
        code: "E0035",
        severity: :error,
        message: "idempotent() can only be used in handler bodies, not in regular functions",
        location: location_from_meta(meta, env.file),
        fix_hint: "Move this to a handler body (handler queue/schedule/http/topic)",
        fix_code: "handler queue \"queue-name\" (msg) -> { idempotent(msg.id) }"
      }
    end)
  end

  defp check_idempotent_in_agent_fns(fns, env) do
    fns
    |> Enum.flat_map(fn %AST.Fn{body: body} ->
      collect_idempotents(body)
    end)
    |> Enum.map(fn meta ->
      %Error{
        code: "E0035",
        severity: :error,
        message: "idempotent() can only be used in handler bodies, not in agent functions",
        location: location_from_meta(meta, env.file),
        fix_hint: "Move this to a handler body (handler queue/schedule/http/topic)",
        fix_code: "handler queue \"queue-name\" (msg) -> { idempotent(msg.id) }"
      }
    end)
  end

  defp collect_idempotents(%AST.Idempotent{meta: meta}), do: [meta]

  defp collect_idempotents(%AST.Block{expressions: exprs}),
    do: Enum.flat_map(exprs, &collect_idempotents/1)

  defp collect_idempotents(%AST.Match{arms: arms}) do
    Enum.flat_map(arms, fn %AST.MatchArm{body: body} -> collect_idempotents(body) end)
  end

  defp collect_idempotents(%AST.Let{value: value}), do: collect_idempotents(value)
  defp collect_idempotents(_), do: []

  # ------------------------------------------------------------------
  # Identifier suggestion (Levenshtein distance)
  # ------------------------------------------------------------------

  # Builds an insertable call snippet with placeholder arguments, used as
  # fix_code for arity errors.
  defp call_skeleton(name, 0), do: "#{name}()"

  defp call_skeleton(name, arity) when arity > 0 do
    args = Enum.map_join(1..arity, ", ", &"arg#{&1}")
    "#{name}(#{args})"
  end

  # A call head like `Foo.bar(...)` refers to another module when `Foo` is an
  # uppercase identifier that is neither a stdlib module nor a locally known
  # name: declared types and enums (variant constructors such as
  # `Status.Banned("spam")`) and tool error types (`SearchError.from(e)`) are
  # not module references.
  defp cross_module_call_head?(mod_name, env) do
    String.match?(mod_name, ~r/^[A-Z]/) and
      mod_name not in @stdlib_modules and
      not Map.has_key?(env.types, mod_name) and
      mod_name not in env.tool_error_names
  end

  defp cross_module_call_error(mod_name, fn_name, arity, meta, env) do
    if mod_name == env.module_name do
      %Error{
        code: "E0016",
        severity: :error,
        message:
          "Module-qualified call '#{mod_name}.#{fn_name}' inside module '#{mod_name}': functions are called unqualified",
        location: location_from_meta(meta, env.file),
        fix_hint:
          "Call '#{fn_name}' directly without the module prefix; qualified calls are reserved for stdlib modules",
        fix_code: call_skeleton(fn_name, arity)
      }
    else
      tool_name = "#{mod_name}.#{camelize_fn_name(fn_name)}"

      %Error{
        code: "E0016",
        severity: :error,
        message:
          "Cross-module function call '#{mod_name}.#{fn_name}': functions are module-private",
        location: location_from_meta(meta, env.file),
        fix_hint:
          "Functions are module-private; expose a tool in '#{mod_name}' and call it with tool.call",
        fix_code:
          "capability tool.use(#{tool_name})\n\nlet result = tool.call(#{tool_name}, { ... })"
      }
    end
  end

  # "fetch_data" -> "FetchData"
  defp camelize_fn_name(fn_name) do
    fn_name
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
  end

  # Picks the candidate closest to the given name, used as fix_code for
  # unknown-name errors.
  defp closest_name(_name, []), do: "name"

  defp closest_name(name, candidates) do
    Enum.max_by(candidates, &String.jaro_distance(&1, name))
  end

  defp first_type_suggestion(name, env) do
    case suggest_types(name, env) do
      "" -> "TypeName"
      suggestions -> suggestions |> String.split(", ") |> List.first()
    end
  end

  defp suggest_identifier(name, env) do
    candidates =
      Map.keys(env.variables) ++ Map.keys(env.functions)

    candidates
    |> Enum.map(fn candidate -> {candidate, levenshtein(name, candidate)} end)
    |> Enum.filter(fn {_, dist} -> dist <= max(2, div(String.length(name), 2)) end)
    |> Enum.sort_by(fn {_, dist} -> dist end)
    |> case do
      [{best, _} | _] -> best
      [] -> nil
    end
  end

  defp levenshtein(s, t) do
    _s_len = String.length(s)
    t_len = String.length(t)
    s_chars = String.graphemes(s)
    t_chars = String.graphemes(t)

    # Build matrix row by row
    first_row = Enum.to_list(0..t_len)

    Enum.reduce(Enum.with_index(s_chars, 1), first_row, fn {s_char, i}, prev_row ->
      Enum.reduce(Enum.with_index(t_chars, 1), {[i], prev_row}, fn {t_char, j},
                                                                   {curr_row, prev} ->
        cost = if s_char == t_char, do: 0, else: 1
        prev_val = Enum.at(prev, j)
        left_val = List.last(curr_row)
        diag_val = Enum.at(prev, j - 1)
        val = Enum.min([prev_val + 1, left_val + 1, diag_val + cost])
        {curr_row ++ [val], prev}
      end)
      |> elem(0)
    end)
    |> List.last()
  end
end
