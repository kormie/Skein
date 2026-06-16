defmodule Skein.CodeGen.CoreErlang do
  @moduledoc """
  Code generator: Skein AST -> Core Erlang -> BEAM bytecode.

  Uses the `:cerl` module to build Core Erlang AST nodes programmatically,
  then calls `:compile.forms/2` to produce `.beam` bytecode.

  ## Variable Naming

  Skein uses snake_case identifiers. Core Erlang requires capitalized variable
  names. We convert by capitalizing the first letter and each letter after an
  underscore, then removing underscores: `my_var` -> `MyVar`.

  ## String Interpolation

  String interpolation compiles to `erlang:iolist_to_binary/1` over a list
  of binary segments.
  """

  alias Skein.AST
  alias Skein.Error
  alias Skein.CodeGen.SchemaGen

  # Known effect namespaces and their runtime modules
  # memory and llm have special codegen handlers below
  @effect_runtime_modules %{
    "http" => :"Elixir.Skein.Runtime.Http",
    "topic" => :"Elixir.Skein.Runtime.Topic",
    "queue" => :"Elixir.Skein.Runtime.Queue",
    "trace" => :"Elixir.Skein.Runtime.Trace",
    "process" => :"Elixir.Skein.Runtime.Process",
    "timer" => :"Elixir.Skein.Runtime.Timer",
    "event" => :"Elixir.Skein.Runtime.EventStore",
    # Nondeterministic generators are effects (#261): uuid.new()/instant.now()
    # lower to capability-checked, replay-aware runtime calls.
    "uuid" => :"Elixir.Skein.Runtime.Uuid",
    "instant" => :"Elixir.Skein.Runtime.Instant"
  }

  # Scoped capability labels (spec §3.2): for these namespaces the declared
  # capability parameter names a scope label (pool/group/stream) that is
  # threaded into every generated runtime call as the first argument,
  # mirroring the memory.kv namespace threading.
  @scoped_effect_capability_kinds %{
    "process" => "process.spawn",
    "timer" => "timer",
    "event" => "event.log"
  }

  # Standard library module mapping: Skein module name -> Elixir runtime module
  @stdlib_modules %{
    "String" => :"Elixir.Skein.Runtime.Stdlib.String",
    "Int" => :"Elixir.Skein.Runtime.Stdlib.Int",
    "Float" => :"Elixir.Skein.Runtime.Stdlib.Float",
    "List" => :"Elixir.Skein.Runtime.Stdlib.List",
    "Map" => :"Elixir.Skein.Runtime.Stdlib.Map",
    "Set" => :"Elixir.Skein.Runtime.Stdlib.Set",
    "Option" => :"Elixir.Skein.Runtime.Stdlib.Option",
    "Result" => :"Elixir.Skein.Runtime.Stdlib.Result",
    "Uuid" => :"Elixir.Skein.Runtime.Stdlib.Uuid",
    "Instant" => :"Elixir.Skein.Runtime.Stdlib.Instant",
    "Duration" => :"Elixir.Skein.Runtime.Stdlib.Duration"
  }

  @stdlib_module_names Map.keys(@stdlib_modules)

  @spec generate(AST.Module.t() | AST.Agent.t()) ::
          {:ok, [{module(), binary()}]} | {:error, [Error.t()]}
  def generate(%AST.Agent{} = ast) do
    reset_var_counter()

    case generate_agent(ast) do
      {:ok, named_binary} -> {:ok, [named_binary]}
      {:error, _} = error -> error
    end
  end

  def generate(%AST.Module{} = ast) do
    reset_var_counter()
    module_atom = String.to_atom("Elixir.Skein.User.#{ast.name}")

    # Extract capabilities for embedding in the module
    capabilities =
      ast.declarations
      |> Enum.filter(&match?(%AST.Capability{}, &1))

    # Collect type and enum declarations for schema resolution
    # (llm.json[T] / req.json[T], including nested record/enum fields).
    type_decls =
      ast.declarations
      |> Enum.filter(&(match?(%AST.TypeDecl{}, &1) or match?(%AST.EnumDecl{}, &1)))
      |> Map.new(fn
        %AST.TypeDecl{name: name} = decl -> {name, decl}
        %AST.EnumDecl{name: name} = decl -> {name, decl}
      end)

    # Collect function declarations
    fns =
      ast.declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))

    # Build function name -> arity map for local call resolution
    fn_arities =
      fns
      |> Map.new(fn f -> {f.name, length(f.params)} end)

    # Collect handler declarations
    handlers =
      ast.declarations
      |> Enum.filter(&match?(%AST.Handler{}, &1))
      |> Enum.with_index()

    # Collect tool declarations. Each tool keeps its index so implement
    # entry points (__tool_impl_N__/1) line up with __tools__/0 metadata.
    tools =
      ast.declarations
      |> Enum.filter(&match?(%AST.ToolDecl{}, &1))
      |> Enum.with_index()

    # Collect supervisor declarations
    supervisors =
      ast.declarations
      |> Enum.filter(&match?(%AST.Supervisor{}, &1))

    # Collect test declarations (test, scenario, golden)
    tests =
      ast.declarations
      |> Enum.filter(fn
        %AST.Test{} -> true
        %AST.Scenario{} -> true
        %AST.Golden{} -> true
        _ -> false
      end)
      |> Enum.with_index()

    # Build exports and function definitions for regular functions
    fn_exports =
      Enum.map(fns, fn f -> :cerl.c_fname(String.to_atom(f.name), length(f.params)) end)

    fn_defs =
      Enum.map(fns, fn f ->
        fname = :cerl.c_fname(String.to_atom(f.name), length(f.params))
        fun = generate_fn(f, capabilities, fn_arities, type_decls)
        {fname, fun}
      end)

    # Build handler exports and definitions
    handler_exports =
      Enum.map(handlers, fn {_handler, index} ->
        :cerl.c_fname(handler_fn_name(index), 1)
      end)

    handler_defs =
      Enum.map(handlers, fn {handler, index} ->
        fname = :cerl.c_fname(handler_fn_name(index), 1)
        fun = generate_handler_fn(handler, capabilities, fn_arities, type_decls)
        {fname, fun}
      end)

    # Build tool implement entry points (__tool_impl_N__/1) for tools
    # declaring an implement block
    implemented_tools =
      Enum.filter(tools, fn {tool, _index} -> tool.implement != nil end)

    tool_impl_exports =
      Enum.map(implemented_tools, fn {_tool, index} ->
        :cerl.c_fname(tool_impl_fn_name(index), 1)
      end)

    tool_impl_defs =
      Enum.map(implemented_tools, fn {tool, index} ->
        fname = :cerl.c_fname(tool_impl_fn_name(index), 1)
        fun = generate_tool_impl_fn(tool, capabilities, fn_arities, type_decls)
        {fname, fun}
      end)

    # Build test exports and definitions
    test_exports =
      Enum.map(tests, fn {_test, index} ->
        :cerl.c_fname(test_fn_name(index), 0)
      end)

    test_defs =
      Enum.map(tests, fn {test_decl, index} ->
        fname = :cerl.c_fname(test_fn_name(index), 0)
        fun = generate_test_fn(test_decl, capabilities, fn_arities, type_decls)
        {fname, fun}
      end)

    # Add __info__/1 for Elixir module compatibility
    info_fname = :cerl.c_fname(:__info__, 1)
    info_fun = generate_info_fn(module_atom, fns)

    # Add __capabilities__/0 for runtime capability access
    caps_fname = :cerl.c_fname(:__capabilities__, 0)
    caps_fun = generate_capabilities_fn(capabilities)

    # Add __handlers__/0 for handler metadata
    handlers_fname = :cerl.c_fname(:__handlers__, 0)
    handlers_fun = generate_handlers_meta_fn(handlers)

    # Add __tools__/0 for tool metadata
    tools_fname = :cerl.c_fname(:__tools__, 0)
    tools_fun = generate_tools_meta_fn(tools)

    # Add __tests__/0 for test metadata
    tests_fname = :cerl.c_fname(:__tests__, 0)
    tests_fun = generate_tests_meta_fn(tests)

    # Add __supervisors__/0 for supervisor metadata
    supervisors_fname = :cerl.c_fname(:__supervisors__, 0)
    supervisors_fun = generate_supervisors_meta_fn(supervisors)

    all_exports =
      [
        info_fname,
        caps_fname,
        handlers_fname,
        tools_fname,
        tests_fname,
        supervisors_fname
        | fn_exports
      ] ++
        handler_exports ++ tool_impl_exports ++ test_exports

    all_defs =
      [
        {info_fname, info_fun},
        {caps_fname, caps_fun},
        {handlers_fname, handlers_fun},
        {tools_fname, tools_fun},
        {tests_fname, tests_fun},
        {supervisors_fname, supervisors_fun}
        | fn_defs
      ] ++ handler_defs ++ tool_impl_defs ++ test_defs

    mod =
      :cerl.c_module(
        :cerl.c_atom(module_atom),
        all_exports,
        [],
        all_defs
      )

    with {:ok, beam_binary} <- compile_core_forms(mod, ast.meta),
         {:ok, agent_modules} <- generate_nested_agents(ast, capabilities, type_decls) do
      {:ok, [{module_atom, beam_binary} | agent_modules]}
    end
  end

  # Agents nested inside a module compile to their own BEAM modules,
  # namespaced under the parent (Skein.Agent.<Module>.<Agent>). They see
  # the module's type declarations (for llm.json[T] schema resolution)
  # and its capabilities in addition to their own.
  defp generate_nested_agents(
         %AST.Module{name: module_name, declarations: declarations},
         module_capabilities,
         type_decls
       ) do
    # Module-level fns are inherited into each nested agent so an agent
    # phase handler (or helper fn) can call them as local functions
    # (skein-testing #8). They were previously invisible to the agent's
    # codegen, so the call lowered to an unbound variable and crashed
    # core_lint.
    module_fns = Enum.filter(declarations, &match?(%AST.Fn{}, &1))

    declarations
    |> Enum.filter(&match?(%AST.Agent{}, &1))
    |> Enum.reduce_while({:ok, []}, fn agent, {:ok, acc} ->
      reset_var_counter()

      opts = [
        namespace: module_name,
        capabilities: agent.capabilities ++ module_capabilities,
        type_decls: type_decls,
        inherited_fns: module_fns
      ]

      case generate_agent(agent, opts) do
        {:ok, named_binary} -> {:cont, {:ok, acc ++ [named_binary]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_core_forms(mod, meta) do
    case :compile.forms(mod, [:from_core, :binary, :return_errors]) do
      {:ok, _, beam_binary} ->
        {:ok, beam_binary}

      {:ok, _, beam_binary, _warnings} ->
        {:ok, beam_binary}

      {:error, errors, _warnings} ->
        {:error,
         [
           %Error{
             code: "E0001",
             severity: :error,
             message: "Core Erlang compilation failed: #{inspect(errors)}",
             location: %{file: meta.file, line: 1, col: 1}
           }
         ]}
    end
  end

  # ------------------------------------------------------------------
  # Agent generation
  # ------------------------------------------------------------------

  defp generate_agent(%AST.Agent{} = ast, opts \\ []) do
    module_atom =
      case Keyword.get(opts, :namespace) do
        nil -> String.to_atom("Elixir.Skein.Agent.#{ast.name}")
        namespace -> String.to_atom("Elixir.Skein.Agent.#{namespace}.#{ast.name}")
      end

    # Nested agents see the enclosing module's capabilities and type
    # declarations in addition to their own.
    capabilities = Keyword.get(opts, :capabilities, ast.capabilities)
    type_decls = Keyword.get(opts, :type_decls, %{})

    # The enclosing module's fns are inherited as local functions of the
    # agent module so phase handlers and helper fns can call them. The
    # agent's own fns win on a name clash.
    agent_fn_names = MapSet.new(ast.fns, & &1.name)

    inherited_fns =
      opts
      |> Keyword.get(:inherited_fns, [])
      |> Enum.reject(&MapSet.member?(agent_fn_names, &1.name))

    agent_fns = ast.fns ++ inherited_fns

    # Build function name -> arity map for local call resolution
    fn_arities =
      agent_fns
      |> Map.new(fn f -> {f.name, length(f.params)} end)

    # Find the start handler
    start_handler =
      Enum.find(ast.handlers, fn h -> h.kind == :start end)

    # Find phase handlers
    phase_handlers =
      Enum.filter(ast.handlers, fn h -> h.kind == :phase end)

    # Generate __info__/1
    info_fname = :cerl.c_fname(:__info__, 1)
    info_fun = generate_agent_info_fn(module_atom, agent_fns)

    # Generate __phases__/0 — returns phase metadata
    phases_fname = :cerl.c_fname(:__phases__, 0)
    phases_fun = generate_phases_fn(ast.phases)

    # Generate start_link/1 — calls Skein.Runtime.Agent.start_link
    start_link_fname = :cerl.c_fname(:start_link, 1)
    start_link_fun = generate_start_link_fn(module_atom)

    # Generate __start_handler__/2 — the on start(...) handler
    start_handler_fname = :cerl.c_fname(:__start_handler__, 2)

    start_handler_fun =
      generate_start_handler_fn(start_handler, capabilities, fn_arities, ast.state, type_decls)

    # Generate __phase_handler__/3 — dispatches to phase-specific handlers
    phase_handler_fname = :cerl.c_fname(:__phase_handler__, 3)

    phase_handler_fun =
      generate_phase_handler_fn(phase_handlers, capabilities, fn_arities, type_decls)

    # Generate user functions (the agent's own plus inherited module fns)
    fn_exports =
      Enum.map(agent_fns, fn f -> :cerl.c_fname(String.to_atom(f.name), length(f.params)) end)

    fn_defs =
      Enum.map(agent_fns, fn f ->
        fname = :cerl.c_fname(String.to_atom(f.name), length(f.params))
        fun = generate_fn(f, capabilities, fn_arities, type_decls)
        {fname, fun}
      end)

    all_exports =
      [
        info_fname,
        phases_fname,
        start_link_fname,
        start_handler_fname,
        phase_handler_fname | fn_exports
      ]

    all_defs =
      [
        {info_fname, info_fun},
        {phases_fname, phases_fun},
        {start_link_fname, start_link_fun},
        {start_handler_fname, start_handler_fun},
        {phase_handler_fname, phase_handler_fun}
      ] ++ fn_defs

    mod =
      :cerl.c_module(
        :cerl.c_atom(module_atom),
        all_exports,
        [],
        all_defs
      )

    case compile_core_forms(mod, ast.meta) do
      {:ok, beam_binary} -> {:ok, {module_atom, beam_binary}}
      {:error, _} = error -> error
    end
  end

  defp generate_agent_info_fn(module_atom, fns) do
    arg = :cerl.c_var(:Info)

    functions_list =
      fns
      |> Enum.map(fn f ->
        :cerl.c_tuple([
          :cerl.c_atom(String.to_atom(f.name)),
          :cerl.c_int(length(f.params))
        ])
      end)
      |> :cerl.make_list()

    module_clause =
      :cerl.c_clause(
        [:cerl.c_atom(:module)],
        :cerl.c_atom(module_atom)
      )

    functions_clause =
      :cerl.c_clause(
        [:cerl.c_atom(:functions)],
        functions_list
      )

    catch_all =
      :cerl.c_clause(
        [:cerl.c_var(:_Other)],
        :cerl.c_atom(:undefined)
      )

    body = :cerl.c_case(arg, [module_clause, functions_clause, catch_all])
    :cerl.c_fun([arg], body)
  end

  defp generate_phases_fn(nil) do
    :cerl.c_fun([], :cerl.make_list([]))
  end

  defp generate_phases_fn(%AST.EnumDecl{variants: variants}) do
    phases_list =
      variants
      |> Enum.map(fn %AST.Variant{name: name, transitions: transitions} ->
        name_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:name),
            :cerl.c_atom(phase_atom(name))
          )

        targets =
          transitions
          |> Enum.map(&:cerl.c_atom(phase_atom(&1)))
          |> :cerl.make_list()

        transitions_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:transitions),
            targets
          )

        :cerl.c_map([name_pair, transitions_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], phases_list)
  end

  defp generate_start_link_fn(module_atom) do
    args_var = :cerl.c_var(:Args)

    body =
      :cerl.c_call(
        :cerl.c_atom(:"Elixir.Skein.Runtime.Agent"),
        :cerl.c_atom(:start_link),
        [:cerl.c_atom(module_atom), args_var]
      )

    :cerl.c_fun([args_var], body)
  end

  defp generate_start_handler_fn(nil, _capabilities, _fn_arities, _state_fields, _type_decls) do
    # No start handler defined — just return keep
    args_var = :cerl.c_var(:_Args)
    state_var = :cerl.c_var(:_State)
    body = :cerl.c_tuple([:cerl.c_atom(:keep), :cerl.c_map([]), :cerl.make_list([])])
    :cerl.c_fun([args_var, state_var], body)
  end

  defp generate_start_handler_fn(
         %AST.AgentHandler{params: params, body: body},
         capabilities,
         fn_arities,
         state_fields,
         type_decls
       ) do
    args_var = :cerl.c_var(:ArgsMap)
    state_var = :cerl.c_var(:StateMap)

    # Build scope: extract params from the args map
    # Each param is accessed as map_get(param_name, args_map)
    scope =
      %{}
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)
      |> Map.put(:__agent_context__, true)
      |> Map.put(:__state_var__, :StateMap)
      |> Map.put(:__state_fields__, Enum.map(state_fields, & &1.name))

    # Bind params from the args map using let bindings
    {body_with_bindings, final_scope} =
      Enum.reduce(params, {nil, scope}, fn %AST.Field{name: name}, {_prev, sc} ->
        vname = var_name(name)
        new_sc = Map.put(sc, name, vname)
        {nil, new_sc}
      end)

    _ = body_with_bindings

    # Generate the body, wrapping param extractions as let bindings
    inner_body = generate_agent_body(body, final_scope)

    # Wrap with let bindings to extract params from the args map
    wrapped =
      Enum.reduce(Enum.reverse(params), inner_body, fn %AST.Field{name: name}, acc ->
        vname = var_name(name)

        extract =
          :cerl.c_call(
            :cerl.c_atom(:erlang),
            :cerl.c_atom(:map_get),
            [:cerl.c_atom(String.to_atom(name)), args_var]
          )

        :cerl.c_let([:cerl.c_var(vname)], extract, acc)
      end)

    :cerl.c_fun([args_var, state_var], wrapped)
  end

  defp generate_phase_handler_fn(phase_handlers, capabilities, fn_arities, type_decls) do
    phase_var = :cerl.c_var(:Phase)
    state_var = :cerl.c_var(:StateMap)
    events_var = :cerl.c_var(:Events)

    # Build a case statement that dispatches on the phase atom
    clauses =
      Enum.map(phase_handlers, fn %AST.AgentHandler{phase: phase_name, body: body} ->
        scope =
          %{}
          |> Map.put(:__capabilities__, capabilities)
          |> Map.put(:__fn_arities__, fn_arities)
          |> Map.put(:__type_decls__, type_decls)
          |> Map.put(:__agent_context__, true)
          |> Map.put(:__state_var__, :StateMap)
          |> Map.put(:__events_var__, :Events)
          |> Map.put(:__state_fields__, [])

        phase_body = generate_agent_body(body, scope)

        :cerl.c_clause(
          [:cerl.c_atom(phase_atom(phase_name))],
          phase_body
        )
      end)

    # Add a catch-all clause
    catch_all =
      :cerl.c_clause(
        [:cerl.c_var(:_Other)],
        :cerl.c_tuple([:cerl.c_atom(:keep), :cerl.c_map([]), :cerl.make_list([])])
      )

    body = :cerl.c_case(phase_var, clauses ++ [catch_all])
    :cerl.c_fun([phase_var, state_var, events_var], body)
  end

  # Generate agent body — wraps expressions so that transition/stop/emit
  # produce the right return tuples
  defp generate_agent_body(%AST.Block{expressions: []}, _scope) do
    :cerl.c_tuple([:cerl.c_atom(:keep), :cerl.c_map([]), :cerl.make_list([])])
  end

  defp generate_agent_body(%AST.Block{expressions: exprs}, scope) do
    generate_agent_sequence(exprs, scope)
  end

  defp generate_agent_body(expr, scope) do
    generate_agent_expr(expr, scope)
  end

  # Agent-specific expression generation
  defp generate_agent_expr(%AST.Transition{phase: phase_name}, _scope) do
    :cerl.c_tuple([
      :cerl.c_atom(:transition),
      :cerl.c_atom(phase_atom(phase_name)),
      :cerl.c_map([]),
      :cerl.make_list([])
    ])
  end

  defp generate_agent_expr(%AST.Stop{}, _scope) do
    :cerl.c_tuple([
      :cerl.c_atom(:stop),
      :cerl.c_map([]),
      :cerl.make_list([])
    ])
  end

  defp generate_agent_expr(%AST.Suspend{reason: reason}, scope) do
    :cerl.c_tuple([
      :cerl.c_atom(:suspend),
      generate_expr(reason, scope),
      :cerl.c_map([]),
      :cerl.make_list([])
    ])
  end

  defp generate_agent_expr(%AST.Emit{event_name: name, fields: fields}, scope) do
    # Build event map
    field_pairs =
      Enum.map(fields, fn {field_name, value_expr} ->
        :cerl.c_map_pair(
          :cerl.c_atom(String.to_atom(field_name)),
          generate_expr(value_expr, scope)
        )
      end)

    event_map =
      :cerl.c_map([
        :cerl.c_map_pair(:cerl.c_atom(:event), :cerl.abstract(name))
        | field_pairs
      ])

    # Return {:keep, state, [event]} — emit doesn't change state or phase
    :cerl.c_tuple([
      :cerl.c_atom(:keep),
      :cerl.c_map([]),
      :cerl.make_list([event_map])
    ])
  end

  defp generate_agent_expr(%AST.Match{subject: subject, arms: arms}, scope) do
    subject_expr = generate_expr(subject, scope)
    clauses = Enum.map(arms, &generate_agent_match_arm(&1, scope))
    :cerl.c_case(subject_expr, ensure_catch_all(clauses, arms))
  end

  defp generate_agent_expr(%AST.Block{} = block, scope) do
    generate_agent_body(block, scope)
  end

  # Field access on "state" — access state map
  defp generate_agent_expr(
         %AST.FieldAccess{subject: %AST.Identifier{name: "state"}, field: field},
         scope
       ) do
    state_var_name = Map.get(scope, :__state_var__, :StateMap)

    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:map_get),
      [:cerl.c_atom(String.to_atom(field)), :cerl.c_var(state_var_name)]
    )
  end

  # Fall through to normal expression generation for other expressions
  defp generate_agent_expr(expr, scope) do
    generate_expr(expr, scope)
  end

  defp generate_agent_match_arm(%AST.MatchArm{pattern: pattern, guard: nil, body: body}, scope) do
    {pat, new_scope} = generate_pattern(pattern, scope)
    body_expr = generate_agent_expr(body, new_scope)
    :cerl.c_clause([pat], body_expr)
  end

  defp generate_agent_match_arm(%AST.MatchArm{pattern: pattern, guard: guard, body: body}, scope) do
    {pat, new_scope} = generate_pattern(pattern, scope)
    guard_expr = generate_expr(guard, new_scope)
    body_expr = generate_agent_expr(body, new_scope)
    :cerl.c_clause([pat], guard_expr, body_expr)
  end

  defp generate_agent_sequence(exprs, scope) do
    generate_agent_sequence(exprs, scope, [])
  end

  # Terminal expression: merge accumulated events into the return tuple
  defp generate_agent_sequence([expr], scope, acc_event_vars) do
    result = generate_agent_expr(expr, scope)
    merge_events_into_result(result, acc_event_vars)
  end

  defp generate_agent_sequence([%AST.Let{name: name, value: value} | rest], scope, acc) do
    vname = var_name(name)
    new_scope = Map.put(scope, name, vname)
    value_expr = generate_expr(value, scope)
    body = generate_agent_sequence(rest, new_scope, acc)
    :cerl.c_let([:cerl.c_var(vname)], value_expr, body)
  end

  defp generate_agent_sequence(
         [%AST.Emit{event_name: name, fields: fields} | rest],
         scope,
         acc
       ) do
    field_pairs =
      Enum.map(fields, fn {field_name, value_expr} ->
        :cerl.c_map_pair(
          :cerl.c_atom(String.to_atom(field_name)),
          generate_expr(value_expr, scope)
        )
      end)

    event_map =
      :cerl.c_map([
        :cerl.c_map_pair(:cerl.c_atom(:event), :cerl.abstract(name))
        | field_pairs
      ])

    event_var = :cerl.c_var(gen_var())
    body = generate_agent_sequence(rest, scope, acc ++ [event_var])
    :cerl.c_let([event_var], event_map, body)
  end

  defp generate_agent_sequence([expr | rest], scope, acc) do
    val = generate_expr(expr, scope)
    body = generate_agent_sequence(rest, scope, acc)
    discard_var = :cerl.c_var(gen_var())
    :cerl.c_let([discard_var], val, body)
  end

  # If there are accumulated events, wrap the result to prepend them to its events list.
  # Result tuples are {action, ..., events_list} — we prepend acc events to that list.
  defp merge_events_into_result(result, []) do
    result
  end

  defp merge_events_into_result(result, acc_event_vars) do
    # Bind the result to a var, extract the events list, prepend accumulated events
    result_var = :cerl.c_var(gen_var())

    # Build: erlang:'++' ([e1, e2, ...], element(tuple_size(result), result))
    acc_list = :cerl.make_list(acc_event_vars)

    # The events list is always the last element of the result tuple.
    # Extract tuple size by case matching the known shapes:
    # {action, state, events} or {action, phase, state, events} or {action, reason, state, events}
    # We'll use a helper: call erlang:append_element equivalent
    # Simpler: extract last element, prepend, rebuild.

    # Actually, the simplest approach: use erlang:setelement to replace the last element
    # with the merged list. But we need to know the tuple size.
    # All agent return tuples have events as last element.
    # Use: erlang:tuple_size/1 to get size, erlang:element/2 to get events, rebuild with setelement.

    size_var = :cerl.c_var(gen_var())
    events_var = :cerl.c_var(gen_var())
    merged_var = :cerl.c_var(gen_var())

    tuple_size_call =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:tuple_size), [result_var])

    get_events =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:element), [size_var, result_var])

    merge_call =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:++), [acc_list, events_var])

    set_events =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:setelement), [
        size_var,
        result_var,
        merged_var
      ])

    # let Result = <result> in
    # let Size = tuple_size(Result) in
    # let Events = element(Size, Result) in
    # let Merged = acc ++ Events in
    # setelement(Size, Result, Merged)
    :cerl.c_let(
      [result_var],
      result,
      :cerl.c_let(
        [size_var],
        tuple_size_call,
        :cerl.c_let([events_var], get_events, :cerl.c_let([merged_var], merge_call, set_events))
      )
    )
  end

  defp phase_atom(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.to_atom()
  end

  # Convert enum variant name to a runtime atom.
  # "Event.Charge" -> :charge, "ChargeSucceeded" -> :charge_succeeded
  # Strips the enum prefix (before the dot) if present and converts to snake_case atom.
  # "Err" maps to :error so Result values line up with the runtime's
  # {:ok, _} | {:error, _} convention ("Ok" -> :ok falls out naturally).
  # erlang comparison function names for Skein comparison operators
  defp comparison_erlang_op(:==), do: :==
  defp comparison_erlang_op(:!=), do: :"/="
  defp comparison_erlang_op(:<), do: :<
  defp comparison_erlang_op(:>), do: :>
  defp comparison_erlang_op(:<=), do: :"=<"
  defp comparison_erlang_op(:>=), do: :>=

  # Builds erlang:error(%Skein.Runtime.AssertionError{...}) with the
  # operand VARS spliced in at runtime and the static context as literals.
  defp raise_assertion_error(op, left_expr, right_expr, expr_ast, meta) do
    error_map =
      :cerl.c_map([
        :cerl.c_map_pair(
          :cerl.c_atom(:__struct__),
          :cerl.c_atom(Skein.Runtime.AssertionError)
        ),
        :cerl.c_map_pair(:cerl.c_atom(:__exception__), :cerl.c_atom(true)),
        :cerl.c_map_pair(:cerl.c_atom(:op), :cerl.c_atom(op)),
        :cerl.c_map_pair(:cerl.c_atom(:left), left_expr),
        :cerl.c_map_pair(:cerl.c_atom(:right), right_expr),
        :cerl.c_map_pair(:cerl.c_atom(:expr), :cerl.abstract(render_source(expr_ast))),
        :cerl.c_map_pair(:cerl.c_atom(:file), :cerl.abstract(Map.get(meta, :file))),
        :cerl.c_map_pair(:cerl.c_atom(:line), :cerl.abstract(Map.get(meta, :line)))
      ])

    :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:error), [error_map])
  end

  # Best-effort source rendering of an assert expression for failure
  # messages. Display-only — falls back to a placeholder for shapes it
  # doesn't know.
  defp render_source(%AST.BinaryOp{op: op, left: left, right: right}) do
    "#{render_source(left)} #{op} #{render_source(right)}"
  end

  defp render_source(%AST.Call{target: target, args: args}) do
    "#{render_source(target)}(#{Enum.map_join(args, ", ", &render_source/1)})"
  end

  defp render_source(%AST.FieldAccess{subject: subject, field: field}) do
    "#{render_source(subject)}.#{field}"
  end

  defp render_source(%AST.Identifier{name: name}), do: name
  defp render_source(%AST.IntLit{value: value}), do: Integer.to_string(value)
  defp render_source(%AST.FloatLit{value: value}), do: Float.to_string(value)
  defp render_source(%AST.BoolLit{value: value}), do: to_string(value)

  defp render_source(%AST.StringLit{segments: segments}) do
    inner =
      Enum.map_join(segments, "", fn
        {:literal, text} -> text
        {:interpolation, expr} -> "${#{render_source(expr)}}"
        _ -> ""
      end)

    ~s("#{inner}")
  end

  defp render_source(%AST.UnaryOp{op: :unwrap, operand: operand}),
    do: "#{render_source(operand)}!"

  defp render_source(%AST.UnaryOp{op: :propagate, operand: operand}),
    do: "#{render_source(operand)}?"

  defp render_source(%AST.UnaryOp{op: _, operand: operand}), do: "-#{render_source(operand)}"

  defp render_source(%AST.ListLit{elements: elements}) do
    "[#{Enum.map_join(elements, ", ", &render_source/1)}]"
  end

  defp render_source(_other), do: "expression"

  defp variant_pattern_atom(name) when is_binary(name) do
    # Take the part after the last dot (the variant name itself)
    base =
      case String.split(name, ".") do
        [_enum, variant] -> variant
        [variant] -> variant
        parts -> List.last(parts)
      end

    case base do
      "Err" ->
        :error

      other ->
        other
        |> to_snake_case()
        |> String.to_atom()
    end
  end

  defp to_snake_case(name) do
    name
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {char, idx} ->
      if idx > 0 and char == String.upcase(char) and char != String.downcase(char) do
        "_" <> String.downcase(char)
      else
        String.downcase(char)
      end
    end)
    |> Enum.join()
  end

  # ------------------------------------------------------------------
  # Function generation
  # ------------------------------------------------------------------

  defp generate_fn(%AST.Fn{params: params, body: body}, capabilities, fn_arities, type_decls) do
    # Create variable bindings for params
    param_vars = Enum.map(params, fn %AST.Field{name: name} -> :cerl.c_var(var_name(name)) end)

    # Build initial scope from params
    scope =
      params
      |> Enum.map(fn %AST.Field{name: name} -> {name, var_name(name)} end)
      |> Map.new()
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)

    body_expr = generate_expr(body, scope)
    :cerl.c_fun(param_vars, body_expr)
  end

  # ------------------------------------------------------------------
  # Handler generation
  # ------------------------------------------------------------------

  defp handler_fn_name(index) do
    String.to_atom("__handler_#{index}__")
  end

  defp generate_handler_fn(
         %AST.Handler{param: param, body: body},
         capabilities,
         fn_arities,
         type_decls
       ) do
    # Handler takes a single argument (request/message map)
    # For schedule handlers with no param, use a discard variable
    {req_var, scope} =
      case param do
        nil ->
          var = :cerl.c_var(:_ScheduleCtx)

          scope =
            %{}
            |> Map.put(:__capabilities__, capabilities)
            |> Map.put(:__fn_arities__, fn_arities)
            |> Map.put(:__type_decls__, type_decls)

          {var, scope}

        _ ->
          var = :cerl.c_var(var_name(param))

          scope =
            %{param => var_name(param)}
            |> Map.put(:__capabilities__, capabilities)
            |> Map.put(:__fn_arities__, fn_arities)
            |> Map.put(:__type_decls__, type_decls)
            |> Map.put(:__handler_req_param__, param)

          {var, scope}
      end

    body_expr = generate_expr(body, scope)
    :cerl.c_fun([req_var], body_expr)
  end

  # Generate __handlers__/0 function that returns handler metadata
  defp generate_handlers_meta_fn(handlers) do
    handlers_list =
      handlers
      |> Enum.map(fn {%AST.Handler{source: source, method: method, route: route}, index} ->
        source_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:source),
            :cerl.c_atom(String.to_atom(source))
          )

        method_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:method),
            if(method, do: :cerl.c_atom(String.to_atom(method)), else: :cerl.c_atom(nil))
          )

        route_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:route),
            :cerl.abstract(route)
          )

        fn_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:handler),
            :cerl.c_atom(handler_fn_name(index))
          )

        :cerl.c_map([source_pair, method_pair, route_pair, fn_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], handlers_list)
  end

  # Generate __capabilities__/0 function that returns capability metadata as a list of maps
  defp generate_capabilities_fn(capabilities) do
    caps_list =
      capabilities
      |> Enum.map(fn %AST.Capability{kind: kind, params: params} ->
        param_strings = Enum.map(params, &capability_param_to_string/1)

        # Build a map: %{kind: kind, params: [param_strings]}
        kind_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:kind),
            :cerl.abstract(kind)
          )

        params_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:params),
            :cerl.abstract(param_strings)
          )

        :cerl.c_map([kind_pair, params_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], caps_list)
  end

  # Shared helper to extract string values from capability params.
  # Handles all AST node types that can appear as capability arguments:
  # - StringLit: `capability memory.kv("sessions")` → "sessions"
  # - ToolRef: `capability tool.use(Stripe.CreateRefund)` → "Stripe.CreateRefund"
  # - Identifier: `capability tool.use(MyTool)` → "MyTool"
  # - Fallback: unknown nodes become "" (graceful degradation)
  defp capability_param_to_string(%AST.StringLit{segments: [{:literal, text}]}), do: text
  defp capability_param_to_string(%AST.StringLit{segments: []}), do: ""
  defp capability_param_to_string(%AST.ToolRef{name: name}), do: name
  defp capability_param_to_string(%AST.Identifier{name: name}), do: name
  defp capability_param_to_string(_), do: ""

  # Extracts the scope label from the first declared capability of a scoped
  # kind (spec §3.2). Parameterless declarations leave the label nil
  # (unscoped — runtime checks presence only). The analyzer's E0017 check
  # guarantees at most one declaration per kind per module/agent scope.
  defp declared_scope_label(capabilities, kind) do
    capabilities
    |> Enum.find(fn %AST.Capability{kind: k} -> k == kind end)
    |> case do
      %AST.Capability{params: [param | _]} -> capability_param_to_string(param)
      _ -> nil
    end
  end

  # Generate __tools__/0 function that returns tool metadata with JSON Schema.
  # Takes {tool, index} pairs; tools with an implement block carry the name
  # of their compiled __tool_impl_N__/1 entry point under :impl (nil otherwise).
  defp generate_tools_meta_fn(tools) do
    tools_list =
      tools
      |> Enum.map(fn {%AST.ToolDecl{name: name, description: desc, input: input, output: output} =
                        tool, index} ->
        name_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:name),
            :cerl.abstract(name)
          )

        impl_atom = if tool.implement, do: tool_impl_fn_name(index), else: nil

        impl_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:impl),
            :cerl.abstract(impl_atom)
          )

        desc_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:description),
            :cerl.abstract(desc)
          )

        # Basic field metadata (backward compatible)
        input_fields =
          (input || [])
          |> Enum.map(fn %AST.Field{name: field_name, type: type} ->
            :cerl.c_map([
              :cerl.c_map_pair(:cerl.c_atom(:name), :cerl.abstract(field_name)),
              :cerl.c_map_pair(:cerl.c_atom(:type), :cerl.abstract(type_ref_to_string(type)))
            ])
          end)
          |> :cerl.make_list()

        input_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:input),
            input_fields
          )

        # JSON Schema for input fields
        input_schema = SchemaGen.fields_to_schema(input || [])

        input_schema_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:input_schema),
            :cerl.abstract(input_schema)
          )

        # JSON Schema for output fields
        output_schema = SchemaGen.fields_to_schema(output || [])

        output_schema_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:output_schema),
            :cerl.abstract(output_schema)
          )

        output_fields =
          (output || [])
          |> Enum.map(fn %AST.Field{name: field_name, type: type} ->
            :cerl.c_map([
              :cerl.c_map_pair(:cerl.c_atom(:name), :cerl.abstract(field_name)),
              :cerl.c_map_pair(:cerl.c_atom(:type), :cerl.abstract(type_ref_to_string(type)))
            ])
          end)
          |> :cerl.make_list()

        output_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:output),
            output_fields
          )

        :cerl.c_map([
          name_pair,
          desc_pair,
          input_pair,
          input_schema_pair,
          output_pair,
          output_schema_pair,
          impl_pair
        ])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], tools_list)
  end

  defp tool_impl_fn_name(index), do: String.to_atom("__tool_impl_#{index}__")

  # Generate a tool's implement block as a 1-arity function taking the
  # input map. Each declared input field is bound from the map (atom keys,
  # matching MapLit codegen) before the body runs, so the implement body
  # references inputs as plain identifiers.
  defp generate_tool_impl_fn(
         %AST.ToolDecl{input: input, implement: body},
         capabilities,
         fn_arities,
         type_decls
       ) do
    input_var = :cerl.c_var(:ToolInput)
    fields = input || []

    scope =
      fields
      |> Map.new(fn %AST.Field{name: name} -> {name, var_name(name)} end)
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)

    inner_body = generate_expr(body, scope)

    wrapped =
      Enum.reduce(Enum.reverse(fields), inner_body, fn %AST.Field{name: name}, acc ->
        extract =
          :cerl.c_call(
            :cerl.c_atom(:erlang),
            :cerl.c_atom(:map_get),
            [:cerl.c_atom(String.to_atom(name)), input_var]
          )

        :cerl.c_let([:cerl.c_var(var_name(name))], extract, acc)
      end)

    :cerl.c_fun([input_var], wrapped)
  end

  # Generate __tests__/0 function that returns test metadata
  defp generate_tests_meta_fn(tests) do
    tests_list =
      tests
      |> Enum.map(fn {test_decl, index} ->
        desc = test_description(test_decl)
        kind = test_kind(test_decl)

        desc_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:description),
            :cerl.abstract(desc)
          )

        fn_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:fn),
            :cerl.c_atom(test_fn_name(index))
          )

        kind_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:kind),
            :cerl.c_atom(kind)
          )

        :cerl.c_map([desc_pair, fn_pair, kind_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], tests_list)
  end

  # Generate __supervisors__/0 function that returns supervisor metadata
  defp generate_supervisors_meta_fn(supervisors) do
    sups_list =
      supervisors
      |> Enum.map(fn %AST.Supervisor{
                       name: name,
                       children: children,
                       strategy: strategy,
                       max_restarts: max_restarts
                     } ->
        name_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:name),
            :cerl.abstract(name)
          )

        strategy_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:strategy),
            :cerl.c_atom(strategy || :one_for_one)
          )

        max_restarts_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:max_restarts),
            case max_restarts do
              {count, period} -> :cerl.c_tuple([:cerl.c_int(count), :cerl.c_int(period)])
              nil -> :cerl.c_atom(nil)
            end
          )

        children_list =
          children
          |> Enum.map(fn %AST.Child{target: target, args: args, options: options} ->
            target_pair =
              :cerl.c_map_pair(:cerl.c_atom(:target), :cerl.abstract(target))

            args_pair =
              :cerl.c_map_pair(:cerl.c_atom(:args), :cerl.abstract(args || []))

            opts_pairs =
              (options || %{})
              |> Enum.map(fn {k, v} ->
                :cerl.c_map_pair(:cerl.c_atom(String.to_atom(k)), :cerl.abstract(v))
              end)

            options_pair =
              :cerl.c_map_pair(
                :cerl.c_atom(:options),
                :cerl.c_map(opts_pairs)
              )

            :cerl.c_map([target_pair, args_pair, options_pair])
          end)
          |> :cerl.make_list()

        children_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:children),
            children_list
          )

        :cerl.c_map([name_pair, strategy_pair, max_restarts_pair, children_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], sups_list)
  end

  defp test_description(%AST.Test{description: d}), do: d
  defp test_description(%AST.Scenario{description: d}), do: d
  defp test_description(%AST.Golden{description: d}), do: d

  defp test_kind(%AST.Test{}), do: :test
  defp test_kind(%AST.Scenario{}), do: :scenario
  defp test_kind(%AST.Golden{}), do: :golden

  defp test_fn_name(index) do
    String.to_atom("__test_#{index}__")
  end

  # Generate a __test_N__/0 function for a test declaration
  defp generate_test_fn(%AST.Test{body: body}, capabilities, fn_arities, type_decls) do
    scope =
      %{}
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)

    body_expr = generate_expr(body, scope)

    # Wrap: run body, then return :ok (body raises on assertion failure)
    discard_var = :cerl.c_var(gen_var())
    wrapped = :cerl.c_let([discard_var], body_expr, :cerl.c_atom(:ok))
    :cerl.c_fun([], wrapped)
  end

  # Generate a __test_N__/0 function for a scenario declaration
  # Scenario tests bind given vars, then execute expect body assertions
  defp generate_test_fn(
         %AST.Scenario{
           capabilities: envelope_caps,
           given_vars: given_vars,
           expect_body: expect_body
         },
         capabilities,
         fn_arities,
         type_decls
       ) do
    base_scope =
      %{}
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)

    # Build scope with all given variable names so the expect body can reference them
    scope_with_given =
      Enum.reduce(given_vars, base_scope, fn {name, _}, sc ->
        Map.put(sc, name, var_name(name))
      end)

    # Generate the expect body expression with given vars in scope
    body_expr = generate_expr(expect_body, scope_with_given)

    # Wrap with let bindings for given vars (innermost first, so reverse)
    wrapped =
      Enum.reduce(Enum.reverse(given_vars), body_expr, fn {name, value_ast}, acc ->
        vname = var_name(name)
        value_expr = generate_expr(value_ast, base_scope)
        :cerl.c_let([:cerl.c_var(vname)], value_expr, acc)
      end)

    # Discard the expect-body result, return :ok.
    discard_var = :cerl.c_var(gen_var())
    body = :cerl.c_let([discard_var], wrapped, :cerl.c_atom(:ok))

    # Register the scenario capability envelopes (#282) BEFORE the body runs, so
    # tool.call pushes them and effects resolve against their `implement`
    # providers. Always registers (an empty map when there are no envelopes) so
    # one scenario's envelopes never leak into the next.
    register = scenario_envelope_registration(envelope_caps || [], base_scope)
    reg_discard = :cerl.c_var(gen_var())
    final = :cerl.c_let([reg_discard], register, body)

    :cerl.c_fun([], final)
  end

  # Generate a __test_N__/0 function for a golden declaration
  # Golden tests load a trace file, make it available, then run assertions
  defp generate_test_fn(
         %AST.Golden{trace_file: trace_file, body: body},
         capabilities,
         fn_arities,
         type_decls
       ) do
    scope =
      %{}
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)
      |> Map.put(:__type_decls__, type_decls)

    # Load the trace file at test execution time
    # Call: Skein.Runtime.Replay.load_trace(trace_file)
    trace_var = :cerl.c_var(gen_var())

    load_trace =
      :cerl.c_call(
        :cerl.c_atom(:"Elixir.Skein.Runtime.Replay"),
        :cerl.c_atom(:load_trace),
        [:cerl.abstract(trace_file)]
      )

    body_expr = generate_expr(body, scope)

    # Run the body INSIDE a replay context so its effect calls intercept the
    # loaded trace instead of hitting live services (Wave 1 golden replay
    # activation): Replay.with_replay(Trace, fn -> Body; :ok end).
    body_discard = :cerl.c_var(gen_var())
    body_fun = :cerl.c_fun([], :cerl.c_let([body_discard], body_expr, :cerl.c_atom(:ok)))

    with_replay =
      :cerl.c_call(
        :cerl.c_atom(:"Elixir.Skein.Runtime.Replay"),
        :cerl.c_atom(:with_replay),
        [trace_var, body_fun]
      )

    # Wrap: load trace, run body under replay, return :ok
    discard_var = :cerl.c_var(gen_var())

    inner = :cerl.c_let([discard_var], with_replay, :cerl.c_atom(:ok))
    wrapped = :cerl.c_let([trace_var], load_trace, inner)
    :cerl.c_fun([], wrapped)
  end

  # Build `Skein.Runtime.CapabilityStack.register_envelopes(%{tool => envelope})`
  # from a scenario's tool.use envelopes (#282).
  defp scenario_envelope_registration(capabilities, base_scope) do
    pairs =
      capabilities
      |> Enum.filter(&match?(%AST.Capability{kind: "tool.use"}, &1))
      |> Enum.map(fn cap ->
        :cerl.c_map_pair(
          :cerl.abstract(tool_use_cap_name(cap)),
          build_tool_envelope(cap, base_scope)
        )
      end)

    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.CapabilityStack"),
      :cerl.c_atom(:register_envelopes),
      [:cerl.c_map(pairs)]
    )
  end

  # A runtime envelope map: %{tool: name, providers: %{kind => fun}, nested: %{tool => envelope}}.
  defp build_tool_envelope(%AST.Capability{nested: nested} = cap, base_scope) do
    nested = nested || []

    provider_pairs =
      nested
      |> Enum.filter(fn c -> c.kind != "tool.use" and c.implement != nil end)
      |> Enum.map(fn c ->
        :cerl.c_map_pair(:cerl.abstract(c.kind), build_provider_closure(c.implement, base_scope))
      end)

    nested_pairs =
      nested
      |> Enum.filter(fn c -> c.kind == "tool.use" end)
      |> Enum.map(fn c ->
        :cerl.c_map_pair(:cerl.abstract(tool_use_cap_name(c)), build_tool_envelope(c, base_scope))
      end)

    :cerl.c_map([
      :cerl.c_map_pair(:cerl.c_atom(:tool), :cerl.abstract(tool_use_cap_name(cap))),
      :cerl.c_map_pair(:cerl.c_atom(:providers), :cerl.c_map(provider_pairs)),
      :cerl.c_map_pair(:cerl.c_atom(:nested), :cerl.c_map(nested_pairs))
    ])
  end

  # An `implement(params) -> T { body }` provider compiles to a closure over its
  # params; the runtime invokes it (0-arity for uuid/instant, 1-arity for
  # http.out/model) when resolving the effect.
  defp build_provider_closure(%AST.CapabilityImplement{params: params, body: body}, base_scope) do
    param_vars = Enum.map(params, fn %AST.Field{name: name} -> :cerl.c_var(var_name(name)) end)

    scope =
      params
      |> Enum.map(fn %AST.Field{name: name} -> {name, var_name(name)} end)
      |> Map.new()
      |> then(&Map.merge(base_scope, &1))

    :cerl.c_fun(param_vars, generate_expr(body, scope))
  end

  defp tool_use_cap_name(%AST.Capability{params: params}) do
    case params do
      [%AST.ToolRef{name: name} | _] -> name
      [%AST.StringLit{segments: [{:literal, name}]} | _] -> name
      _ -> nil
    end
  end

  defp type_ref_to_string(%AST.TypeRef{name: name, params: []}) do
    name
  end

  defp type_ref_to_string(%AST.TypeRef{name: name, params: params}) do
    param_strs = Enum.map(params, &type_ref_to_string/1)
    "#{name}[#{Enum.join(param_strs, ", ")}]"
  end

  # Generate a minimal __info__/1 function for Elixir interop
  defp generate_info_fn(module_atom, fns) do
    arg = :cerl.c_var(:Info)

    functions_list =
      fns
      |> Enum.map(fn f ->
        :cerl.c_tuple([
          :cerl.c_atom(String.to_atom(f.name)),
          :cerl.c_int(length(f.params))
        ])
      end)
      |> :cerl.make_list()

    module_clause =
      :cerl.c_clause(
        [:cerl.c_atom(:module)],
        :cerl.c_atom(module_atom)
      )

    functions_clause =
      :cerl.c_clause(
        [:cerl.c_atom(:functions)],
        functions_list
      )

    catch_all =
      :cerl.c_clause(
        [:cerl.c_var(:_Other)],
        :cerl.c_atom(:undefined)
      )

    body = :cerl.c_case(arg, [module_clause, functions_clause, catch_all])
    :cerl.c_fun([arg], body)
  end

  # ------------------------------------------------------------------
  # Expression generation
  # ------------------------------------------------------------------

  # Block: sequence of expressions using nested let bindings
  defp generate_expr(%AST.Block{expressions: []}, _scope) do
    :cerl.c_atom(:ok)
  end

  defp generate_expr(%AST.Block{expressions: [expr]}, scope) do
    generate_expr(expr, scope)
  end

  defp generate_expr(%AST.Block{expressions: exprs}, scope) do
    generate_sequence(exprs, scope)
  end

  # Let binding
  defp generate_expr(%AST.Let{name: _name, value: value}, scope) do
    # The Let node generates a value; the sequencing in generate_sequence
    # handles binding it with c_let
    generate_expr(value, scope)
  end

  # Match expression
  defp generate_expr(%AST.Match{subject: subject, arms: arms}, scope) do
    subject_expr = generate_expr(subject, scope)
    clauses = Enum.map(arms, &generate_match_arm(&1, scope))
    :cerl.c_case(subject_expr, ensure_catch_all(clauses, arms))
  end

  # Binary operations
  # Division: use runtime dispatch to pick integer div vs float /
  defp generate_expr(%AST.BinaryOp{op: :/, left: left, right: right}, scope) do
    left_expr = generate_expr(left, scope)
    right_expr = generate_expr(right, scope)

    left_var = :cerl.c_var(gen_var())
    right_var = :cerl.c_var(gen_var())

    # is_float(L) orelse is_float(R)
    left_is_float =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:is_float), [left_var])

    right_is_float =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:is_float), [right_var])

    either_float =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:or), [left_is_float, right_is_float])

    float_div =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:/), [left_var, right_var])

    int_div =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:div), [left_var, right_var])

    # case (is_float(L) or is_float(R)) of true -> L / R ; false -> div(L, R)
    case_expr =
      :cerl.c_case(either_float, [
        :cerl.c_clause([:cerl.c_atom(true)], float_div),
        :cerl.c_clause([:cerl.c_atom(false)], int_div)
      ])

    # let L = left_expr in let R = right_expr in case ...
    :cerl.c_let([right_var], right_expr, case_expr)
    |> then(fn inner -> :cerl.c_let([left_var], left_expr, inner) end)
  end

  defp generate_expr(%AST.BinaryOp{op: op, left: left, right: right}, scope) do
    left_expr = generate_expr(left, scope)
    right_expr = generate_expr(right, scope)

    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(erlang_op(op)),
      [left_expr, right_expr]
    )
  end

  # Unary operations
  defp generate_expr(%AST.UnaryOp{op: :not, operand: operand}, scope) do
    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:not),
      [generate_expr(operand, scope)]
    )
  end

  defp generate_expr(%AST.UnaryOp{op: :negate, operand: operand}, scope) do
    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:-),
      [generate_expr(operand, scope)]
    )
  end

  defp generate_expr(%AST.UnaryOp{op: :unwrap, operand: operand}, scope) do
    # Unwrap Result: pattern match, crash on error
    result_var = :cerl.c_var(gen_var())
    result_expr = generate_expr(operand, scope)

    ok_var = :cerl.c_var(gen_var())

    ok_clause =
      :cerl.c_clause(
        [:cerl.c_tuple([:cerl.c_atom(:ok), ok_var])],
        ok_var
      )

    err_var = :cerl.c_var(gen_var())

    err_clause =
      :cerl.c_clause(
        [:cerl.c_tuple([:cerl.c_atom(:error), err_var])],
        :cerl.c_call(
          :cerl.c_atom(:erlang),
          :cerl.c_atom(:error),
          [err_var]
        )
      )

    :cerl.c_let(
      [result_var],
      result_expr,
      :cerl.c_case(result_var, [ok_clause, err_clause])
    )
  end

  defp generate_expr(%AST.UnaryOp{op: :propagate, operand: operand}, scope) do
    # Propagate Result: pattern match, return error tuple on error
    result_var = :cerl.c_var(gen_var())
    result_expr = generate_expr(operand, scope)

    ok_var = :cerl.c_var(gen_var())

    ok_clause =
      :cerl.c_clause(
        [:cerl.c_tuple([:cerl.c_atom(:ok), ok_var])],
        ok_var
      )

    err_var = :cerl.c_var(gen_var())

    err_clause =
      :cerl.c_clause(
        [:cerl.c_tuple([:cerl.c_atom(:error), err_var])],
        :cerl.c_tuple([:cerl.c_atom(:error), err_var])
      )

    :cerl.c_let(
      [result_var],
      result_expr,
      :cerl.c_case(result_var, [ok_clause, err_clause])
    )
  end

  # Pipe expression: left |> right
  # The piped value becomes the first argument of the right-hand call, so
  # the desugared Call hits the regular stdlib/local/effect call clauses.
  defp generate_expr(%AST.Pipe{left: left, right: %AST.Call{args: args} = call}, scope) do
    generate_expr(%{call | args: [left | args]}, scope)
  end

  defp generate_expr(%AST.Pipe{left: left, right: right}, scope) do
    # The right side is a function reference; apply it
    left_expr = generate_expr(left, scope)
    right_expr = generate_expr(right, scope)
    :cerl.c_apply(right_expr, [left_expr])
  end

  # Standard library call: Module.function(args) where Module is a stdlib module
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: mod_name},
             field: fn_name
           },
           args: args
         },
         scope
       )
       when mod_name in @stdlib_module_names do
    runtime_module = Map.fetch!(@stdlib_modules, mod_name)
    method_atom = String.to_atom(fn_name)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    :cerl.c_call(
      :cerl.c_atom(runtime_module),
      :cerl.c_atom(method_atom),
      args_exprs
    )
  end

  # idempotent(key) — generates call to Skein.Runtime.Idempotent.check!(key)
  defp generate_expr(%AST.Idempotent{key: key}, scope) do
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Idempotent"),
      :cerl.c_atom(:check!),
      [generate_expr(key, scope)]
    )
  end

  # respond.json(status, body) — generates a response tuple
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "respond"},
             field: "json"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    case args_exprs do
      [status_expr, body_expr] ->
        # Return {:respond_json, status, body}
        :cerl.c_tuple([
          :cerl.c_atom(:respond_json),
          status_expr,
          body_expr
        ])

      _ ->
        # Fallback: return the args as a tuple
        :cerl.c_tuple([:cerl.c_atom(:respond_json) | args_exprs])
    end
  end

  # respond.text(status, body) — generates a text response tuple
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "respond"},
             field: "text"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    case args_exprs do
      [status_expr, body_expr] ->
        :cerl.c_tuple([
          :cerl.c_atom(:respond_text),
          status_expr,
          body_expr
        ])

      _ ->
        :cerl.c_tuple([:cerl.c_atom(:respond_text) | args_exprs])
    end
  end

  # respond.html(status, body) — generates an HTML response tuple
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "respond"},
             field: "html"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    case args_exprs do
      [status_expr, body_expr] ->
        :cerl.c_tuple([
          :cerl.c_atom(:respond_html),
          status_expr,
          body_expr
        ])

      _ ->
        :cerl.c_tuple([:cerl.c_atom(:respond_html) | args_exprs])
    end
  end

  # Store effect: store.<table>.<method>(...)
  # Pattern: Call(FieldAccess(FieldAccess(Identifier("store"), table), method), args)
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.FieldAccess{
               subject: %AST.Identifier{name: "store"},
               field: table_name
             },
             field: method
           },
           args: args
         },
         scope
       )
       when method in ["get", "get!", "put", "put!", "delete", "query"] do
    method_atom = String.to_atom(method)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Call: Skein.Runtime.Store.method(table_name, args..., capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Store"),
      :cerl.c_atom(method_atom),
      [:cerl.abstract(table_name) | args_exprs] ++ [caps_expr]
    )
  end

  # Memory effect: memory.put(key, value), memory.get(key), etc.
  # Injects namespace from capabilities as the first argument.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "memory"},
             field: method
           },
           args: args
         },
         scope
       )
       when method in ["put", "get", "get!", "delete", "list"] do
    method_atom = String.to_atom(method)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Extract namespace from the first memory.kv capability
    namespace =
      capabilities
      |> Enum.find(fn %AST.Capability{kind: kind} -> kind == "memory.kv" end)
      |> case do
        %AST.Capability{params: [%AST.StringLit{segments: [{:literal, ns}]} | _]} -> ns
        _ -> "default"
      end

    # Call: Skein.Runtime.Memory.method(namespace, args..., capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Memory"),
      :cerl.c_atom(method_atom),
      [:cerl.abstract(namespace) | args_exprs] ++ [caps_expr]
    )
  end

  # Request body parsing: req.json[T] — parses and validates JSON body against type schema
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: subject_name},
             field: "json"
           },
           args: [],
           type_param: %AST.TypeRef{name: type_name} = _type_param
         },
         scope
       )
       when is_binary(subject_name) do
    handler_param = Map.get(scope, :__handler_req_param__)

    if handler_param == subject_name do
      # This is req.json[T] — generate call to Skein.Runtime.Request.json(req, schema)
      req_var = :cerl.c_var(Map.get(scope, subject_name))

      type_decls = Map.get(scope, :__type_decls__, %{})
      schema = json_schema_for(type_name, type_decls)

      schema_expr = :cerl.abstract(schema)

      :cerl.c_call(
        :cerl.c_atom(:"Elixir.Skein.Runtime.Request"),
        :cerl.c_atom(:json),
        [req_var, schema_expr]
      )
    else
      # Not the handler request param — fall through to generic field access
      subject_expr = generate_expr(%AST.Identifier{name: subject_name, meta: %{}}, scope)

      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:map_get), [
        :cerl.c_atom(:json),
        subject_expr
      ])
    end
  end

  # LLM effect: llm.json[T](model, system, input) — with type-parameterized schema
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "llm"},
             field: "json"
           },
           args: args,
           type_param: type_param
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Generate schema from type parameter if present, otherwise empty map
    schema =
      case type_param do
        %AST.TypeRef{name: type_name} ->
          type_decls = Map.get(scope, :__type_decls__, %{})
          json_schema_for(type_name, type_decls)

        _ ->
          %{}
      end

    schema_expr = :cerl.abstract(schema)

    # Call: Skein.Runtime.Llm.json(model, system, input, schema, capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Llm"),
      :cerl.c_atom(:json),
      args_exprs ++ [schema_expr, caps_expr]
    )
  end

  # LLM effect: llm.chat(model, system, input) — standard pattern
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "llm"},
             field: "chat"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Call: Skein.Runtime.Llm.chat(model, system, input, capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Llm"),
      :cerl.c_atom(:chat),
      args_exprs ++ [caps_expr]
    )
  end

  # LLM effect: llm.stream(model, system, input[, on_chunk]) — the optional
  # fourth argument fills the runtime callback slot; without it a no-op
  # callback keeps the stream/5 arity.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "llm"},
             field: "stream"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    callback_exprs =
      if length(args) >= 4 do
        []
      else
        # Build a no-op callback: fun (Chunk) -> ok
        chunk_var = :cerl.c_var(:_StreamChunk)
        [:cerl.c_fun([chunk_var], :cerl.c_atom(:ok))]
      end

    # Call: Skein.Runtime.Llm.stream(model, system, input, on_chunk, capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Llm"),
      :cerl.c_atom(:stream),
      args_exprs ++ callback_exprs ++ [caps_expr]
    )
  end

  # LLM effect: llm.embed(model, input) — returns embedding vector
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "llm"},
             field: "embed"
           },
           args: args
         },
         scope
       ) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Call: Skein.Runtime.Llm.embed(model, input, capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Llm"),
      :cerl.c_atom(:embed),
      args_exprs ++ [caps_expr]
    )
  end

  # Tool effect: tool.call(name, args), tool.list(), tool.schema(name)
  # For tool.call and tool.schema, the first arg may be an identifier-based
  # tool reference (e.g., MyTool or Stripe.CreateRefund) that must be lowered
  # to a runtime string. tool.list() has no tool name arg.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: "tool"},
             field: method
           },
           args: args
         },
         scope
       )
       when method in ["call", "list", "schema"] do
    method_atom = String.to_atom(method)

    args_exprs =
      case {method, args} do
        {m, [first_arg | rest_args]} when m in ["call", "schema"] ->
          # Lower tool identifier references to string literals for the runtime
          first_expr = lower_tool_ref_arg(first_arg, scope)
          rest_exprs = Enum.map(rest_args, &generate_expr(&1, scope))
          [first_expr | rest_exprs]

        _ ->
          Enum.map(args, &generate_expr(&1, scope))
      end

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Call: Skein.Runtime.Tool.method(args..., capabilities)
    :cerl.c_call(
      :cerl.c_atom(:"Elixir.Skein.Runtime.Tool"),
      :cerl.c_atom(method_atom),
      args_exprs ++ [caps_expr]
    )
  end

  # Scoped effect call: process.spawn(...), timer.after(...), event.log(...).
  # The declared capability label (pool/group/stream) is threaded into the
  # runtime call as the first argument (spec §3.2). The first capability of
  # the kind wins; nested agents list their own capabilities before the
  # module's, so an agent-level label overrides the module's.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: namespace},
             field: method
           },
           args: args
         },
         scope
       )
       when is_map_key(@scoped_effect_capability_kinds, namespace) do
    runtime_module = Map.fetch!(@effect_runtime_modules, namespace)
    method_atom = String.to_atom(method)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    label =
      declared_scope_label(capabilities, Map.fetch!(@scoped_effect_capability_kinds, namespace))

    # Call: RuntimeModule.method(label, args..., capabilities)
    :cerl.c_call(
      :cerl.c_atom(runtime_module),
      :cerl.c_atom(method_atom),
      [:cerl.abstract(label) | args_exprs] ++ [caps_expr]
    )
  end

  # Effect call: http.get(...), http.post(...), etc.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: namespace},
             field: method
           },
           args: args
         },
         scope
       )
       when is_map_key(@effect_runtime_modules, namespace) do
    runtime_module = Map.fetch!(@effect_runtime_modules, namespace)
    method_atom = String.to_atom(method)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))

    # Build capabilities literal from scope
    capabilities = Map.get(scope, :__capabilities__, [])
    caps_expr = generate_capabilities_literal(capabilities)

    # Call: RuntimeModule.method(args..., capabilities)
    :cerl.c_call(
      :cerl.c_atom(runtime_module),
      :cerl.c_atom(method_atom),
      args_exprs ++ [caps_expr]
    )
  end

  # Assert expression: __assert__(expr) — raises a structured
  # Skein.Runtime.AssertionError on falsy (issue #105). Comparison asserts
  # bind both operands so the failure reports expected vs actual; every
  # assert carries the rendered expression and its source location.
  @comparison_ops [:==, :!=, :<, :>, :<=, :>=]

  defp generate_expr(
         %AST.Call{
           target: %AST.Identifier{name: "__assert__", meta: meta},
           args: [%AST.BinaryOp{op: op, left: left, right: right} = expr]
         },
         scope
       )
       when op in @comparison_ops do
    left_var = :cerl.c_var(gen_var())
    right_var = :cerl.c_var(gen_var())
    result_var = :cerl.c_var(gen_var())

    compare =
      :cerl.c_call(
        :cerl.c_atom(:erlang),
        :cerl.c_atom(comparison_erlang_op(op)),
        [left_var, right_var]
      )

    ok_clause = :cerl.c_clause([:cerl.c_atom(true)], :cerl.c_atom(:ok))

    fail_clause =
      :cerl.c_clause(
        [:cerl.c_var(:_AssertVal)],
        raise_assertion_error(op, left_var, right_var, expr, meta)
      )

    :cerl.c_let(
      [left_var],
      generate_expr(left, scope),
      :cerl.c_let(
        [right_var],
        generate_expr(right, scope),
        :cerl.c_let(
          [result_var],
          compare,
          :cerl.c_case(result_var, [ok_clause, fail_clause])
        )
      )
    )
  end

  defp generate_expr(
         %AST.Call{target: %AST.Identifier{name: "__assert__", meta: meta}, args: [expr]},
         scope
       ) do
    expr_val = generate_expr(expr, scope)
    result_var = :cerl.c_var(gen_var())

    ok_clause = :cerl.c_clause([:cerl.c_atom(true)], :cerl.c_atom(:ok))

    fail_clause =
      :cerl.c_clause(
        [:cerl.c_var(:_AssertVal)],
        raise_assertion_error(nil, :cerl.c_atom(nil), :cerl.c_atom(nil), expr, meta)
      )

    :cerl.c_let(
      [result_var],
      expr_val,
      :cerl.c_case(result_var, [ok_clause, fail_clause])
    )
  end

  # Result/enum variant construction in expression position: Ok(x), Err(e),
  # ChargeSucceeded(id, amount). Mirrors generate_pattern's variant handling
  # so constructed values match their patterns: {:variant_atom, Arg1, ...}.
  # Skein function names are lowercase, so an uppercase call target is
  # always a variant constructor.
  defp generate_expr(%AST.Call{target: %AST.Identifier{name: name}, args: args}, scope)
       when binary_part(name, 0, 1) >= "A" and binary_part(name, 0, 1) <= "Z" do
    case Enum.map(args, &generate_expr(&1, scope)) do
      # Zero-field variants are bare atoms, matching the pattern side
      [] -> :cerl.c_atom(variant_pattern_atom(name))
      args_exprs -> :cerl.c_tuple([:cerl.c_atom(variant_pattern_atom(name)) | args_exprs])
    end
  end

  # Error conversion: ErrName.from(cause) wraps a cause in a declared error
  # variant, e.g. SearchError.from(e) -> {:search_error, E}. This is the
  # spec section 8.4 pattern for implement-block error handling.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: error_name},
             field: "from"
           },
           args: [arg]
         },
         scope
       )
       when binary_part(error_name, 0, 1) >= "A" and binary_part(error_name, 0, 1) <= "Z" do
    :cerl.c_tuple([
      :cerl.c_atom(variant_pattern_atom(error_name)),
      generate_expr(arg, scope)
    ])
  end

  # Dotted enum variant construction: Event.Charge(amount) -> {:charge, Amount}.
  # Stdlib modules (String.upcase, Result.ok, ...) and effect namespaces are
  # matched by earlier clauses, so an Upper.Upper(...) call here is always a
  # variant constructor.
  defp generate_expr(
         %AST.Call{
           target: %AST.FieldAccess{
             subject: %AST.Identifier{name: enum_name},
             field: variant_name
           },
           args: args
         },
         scope
       )
       when binary_part(enum_name, 0, 1) >= "A" and binary_part(enum_name, 0, 1) <= "Z" and
              binary_part(variant_name, 0, 1) >= "A" and binary_part(variant_name, 0, 1) <= "Z" do
    case Enum.map(args, &generate_expr(&1, scope)) do
      # Zero-field variants are bare atoms, matching the pattern side
      [] -> :cerl.c_atom(variant_pattern_atom(variant_name))
      args_exprs -> :cerl.c_tuple([:cerl.c_atom(variant_pattern_atom(variant_name)) | args_exprs])
    end
  end

  # Function call
  defp generate_expr(%AST.Call{target: %AST.Identifier{name: name}, args: args}, scope) do
    args_exprs = Enum.map(args, &generate_expr(&1, scope))
    fn_arities = Map.get(scope, :__fn_arities__, %{})

    case Map.get(fn_arities, name) do
      nil ->
        target_expr = generate_expr(%AST.Identifier{name: name, meta: %{}}, scope)
        generate_call(target_expr, args_exprs)

      _arity ->
        # Known local function: use c_fname for proper Core Erlang local call
        fname = :cerl.c_fname(String.to_atom(name), length(args_exprs))
        :cerl.c_apply(fname, args_exprs)
    end
  end

  defp generate_expr(%AST.Call{target: target, args: args}, scope) do
    target_expr = generate_expr(target, scope)
    args_exprs = Enum.map(args, &generate_expr(&1, scope))
    generate_call(target_expr, args_exprs)
  end

  # Agent state access in nested expression positions (let values, call
  # args, match subjects). The top-level case is handled by
  # generate_agent_expr; this clause covers everything routed through plain
  # generate_expr. A user binding named "state" takes precedence.
  defp generate_expr(
         %AST.FieldAccess{subject: %AST.Identifier{name: "state"}, field: field},
         %{__state_var__: state_var} = scope
       )
       when not is_map_key(scope, "state") do
    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:map_get),
      [:cerl.c_atom(String.to_atom(field)), :cerl.c_var(state_var)]
    )
  end

  # Zero-field enum variant reference: Status.Active -> :active. Stdlib
  # and effect namespaces only have lowercase fields, so Upper.Upper here
  # is always a variant reference (the analyzer has already validated it).
  defp generate_expr(
         %AST.FieldAccess{subject: %AST.Identifier{name: enum_name}, field: variant_name},
         _scope
       )
       when binary_part(enum_name, 0, 1) >= "A" and binary_part(enum_name, 0, 1) <= "Z" and
              binary_part(variant_name, 0, 1) >= "A" and binary_part(variant_name, 0, 1) <= "Z" do
    :cerl.c_atom(variant_pattern_atom(variant_name))
  end

  # Field access
  defp generate_expr(%AST.FieldAccess{subject: subject, field: field}, scope) do
    # For now, we represent field access as module.function pattern
    # In codegen, Foo.bar becomes a reference to module Foo, function bar
    case subject do
      %AST.Identifier{name: name} when is_binary(name) ->
        first_char = String.at(name, 0)

        if first_char == String.upcase(first_char) and first_char != "_" do
          # Module.function reference - just produce an identifier
          # This will be resolved when used in a Call context
          :cerl.c_var(var_name("#{name}_#{field}"))
        else
          # Instance field access - for now, map get
          :cerl.c_call(
            :cerl.c_atom(:erlang),
            :cerl.c_atom(:map_get),
            [:cerl.c_atom(String.to_atom(field)), generate_expr(subject, scope)]
          )
        end

      %AST.FieldAccess{} ->
        # Nested field access on non-module - map access
        :cerl.c_call(
          :cerl.c_atom(:erlang),
          :cerl.c_atom(:map_get),
          [:cerl.c_atom(String.to_atom(field)), generate_expr(subject, scope)]
        )

      _ ->
        :cerl.c_call(
          :cerl.c_atom(:erlang),
          :cerl.c_atom(:map_get),
          [:cerl.c_atom(String.to_atom(field)), generate_expr(subject, scope)]
        )
    end
  end

  # Literals
  defp generate_expr(%AST.IntLit{value: value}, _scope) do
    :cerl.c_int(value)
  end

  defp generate_expr(%AST.FloatLit{value: value}, _scope) do
    :cerl.c_float(value)
  end

  defp generate_expr(%AST.BoolLit{value: value}, _scope) do
    :cerl.c_atom(value)
  end

  defp generate_expr(%AST.StringLit{segments: []}, _scope) do
    :cerl.abstract("")
  end

  defp generate_expr(%AST.StringLit{segments: [{:literal, text}]}, _scope) do
    :cerl.abstract(text)
  end

  defp generate_expr(%AST.StringLit{segments: segments}, scope) do
    # String with interpolation: build iolist and call erlang:iolist_to_binary/1.
    # Interpolation segments are ordinary AST nodes (Identifier/FieldAccess),
    # so the regular expression generator handles them — including agent
    # state access via the __state_var__ scope.
    parts =
      Enum.map(segments, fn
        {:literal, text} ->
          :cerl.abstract(text)

        {:interpolation, expr} ->
          interpolation_to_binary(generate_expr(expr, scope))
      end)

    iolist = :cerl.make_list(parts)

    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:iolist_to_binary),
      [iolist]
    )
  end

  # List literal
  defp generate_expr(%AST.ListLit{elements: elements}, scope) do
    elements
    |> Enum.map(&generate_expr(&1, scope))
    |> :cerl.make_list()
  end

  # Map literal
  defp generate_expr(%AST.MapLit{entries: entries}, scope) do
    pairs =
      Enum.map(entries, fn {key, value} ->
        {:cerl.c_atom(String.to_atom(key)), generate_expr(value, scope)}
      end)

    :cerl.c_map(pairs |> Enum.map(fn {k, v} -> :cerl.c_map_pair(k, v) end))
  end

  # Record literal: same atom-keyed map representation as user-type values, so
  # field access (map_get) reads it back. The type name is analyzer-only.
  defp generate_expr(%AST.RecordLit{fields: fields}, scope) do
    pairs =
      Enum.map(fields, fn {key, value} ->
        :cerl.c_map_pair(:cerl.c_atom(String.to_atom(key)), generate_expr(value, scope))
      end)

    :cerl.c_map(pairs)
  end

  # Identifier
  defp generate_expr(%AST.Identifier{name: name}, scope)
       when binary_part(name, 0, 1) >= "A" and binary_part(name, 0, 1) <= "Z" do
    case Map.get(scope, name) do
      # Bindings are lowercase by grammar, so an unbound uppercase
      # identifier is a zero-field variant reference (analyzer-validated)
      nil -> :cerl.c_atom(variant_pattern_atom(name))
      var -> :cerl.c_var(var)
    end
  end

  defp generate_expr(%AST.Identifier{name: name}, scope) do
    case Map.get(scope, name) do
      nil ->
        # Could be a module reference or unresolved - use the raw name
        :cerl.c_var(var_name(name))

      var ->
        :cerl.c_var(var)
    end
  end

  # FnRef — generate a proper function reference (lambda wrapper around local function)
  defp generate_expr(%AST.FnRef{name: name}, scope) do
    fn_arities = Map.get(scope, :__fn_arities__, %{})

    case Map.get(fn_arities, name) do
      nil ->
        # Unknown function — fall back to variable reference
        :cerl.c_var(var_name(name))

      arity ->
        # Known local function — wrap in a lambda so it's a passable function value
        args =
          for i <- 0..max(arity - 1, 0)//1,
              arity > 0,
              do: :cerl.c_var(String.to_atom("_FnRef_#{i}"))

        fname = :cerl.c_fname(String.to_atom(name), arity)
        :cerl.c_fun(args, :cerl.c_apply(fname, args))
    end
  end

  # ------------------------------------------------------------------
  # Tool reference lowering helpers
  # ------------------------------------------------------------------

  # Lower a tool reference argument to a runtime string.
  # ToolRef nodes (produced by the parser) carry the full dotted name directly.
  defp lower_tool_ref_arg(%AST.ToolRef{name: name}, _scope) do
    :cerl.abstract(name)
  end

  defp lower_tool_ref_arg(expr, scope), do: generate_expr(expr, scope)

  # ------------------------------------------------------------------
  # Match arm generation
  # ------------------------------------------------------------------

  defp generate_match_arm(%AST.MatchArm{pattern: pattern, guard: nil, body: body}, scope) do
    {pat, new_scope} = generate_pattern(pattern, scope)
    body_expr = generate_expr(body, new_scope)
    :cerl.c_clause([pat], body_expr)
  end

  # Guarded arm: the analyzer restricts guards to expressions whose codegen
  # is guard-safe (literals, vars, map_get, single erlang calls), so the
  # ordinary expression generator produces a valid Core Erlang clause guard.
  defp generate_match_arm(%AST.MatchArm{pattern: pattern, guard: guard, body: body}, scope) do
    {pat, new_scope} = generate_pattern(pattern, scope)
    guard_expr = generate_expr(guard, new_scope)
    body_expr = generate_expr(body, new_scope)
    :cerl.c_clause([pat], guard_expr, body_expr)
  end

  # A case whose clauses can all fail (e.g. only literal patterns) needs an
  # explicit failure clause: the BEAM validator rejects implicit fail paths
  # for binary patterns. The added clause preserves the runtime semantics of
  # a non-exhaustive match (a case_clause error).
  defp ensure_catch_all(clauses, arms) do
    exhaustive? =
      Enum.any?(arms, fn %AST.MatchArm{pattern: pattern, guard: guard} ->
        is_nil(guard) and catch_all_pattern?(pattern)
      end)

    if exhaustive? do
      clauses
    else
      var = :cerl.c_var(gen_var())

      raise_case_clause =
        :cerl.c_call(
          :cerl.c_atom(:erlang),
          :cerl.c_atom(:error),
          [:cerl.c_tuple([:cerl.c_atom(:case_clause), var])]
        )

      clauses ++ [:cerl.c_clause([var], raise_case_clause)]
    end
  end

  defp catch_all_pattern?(%AST.Wildcard{}), do: true

  defp catch_all_pattern?(%AST.Identifier{name: name}) do
    first_char = String.at(name, 0)
    first_char != String.upcase(first_char) or first_char == "_"
  end

  defp catch_all_pattern?(_), do: false

  defp generate_pattern(%AST.BoolLit{value: value}, scope) do
    {:cerl.c_atom(value), scope}
  end

  defp generate_pattern(%AST.IntLit{value: value}, scope) do
    {:cerl.c_int(value), scope}
  end

  # String literals in pattern position must be Core Erlang binary patterns
  # (one 8-bit segment per byte) — a plain binary c_literal in a clause
  # pattern crashes the BEAM compiler's core_to_ssa pass.
  defp generate_pattern(%AST.StringLit{segments: []}, scope) do
    {:cerl.c_binary([]), scope}
  end

  defp generate_pattern(%AST.StringLit{segments: [{:literal, text}]}, scope) do
    segments =
      for <<byte <- text>> do
        :cerl.c_bitstr(
          :cerl.c_int(byte),
          :cerl.c_int(8),
          :cerl.c_int(1),
          :cerl.c_atom(:integer),
          :cerl.abstract([:unsigned, :big])
        )
      end

    {:cerl.c_binary(segments), scope}
  end

  defp generate_pattern(%AST.Identifier{name: name}, scope) do
    first_char = String.at(name, 0)

    if first_char == String.upcase(first_char) and first_char != "_" do
      # Uppercase identifier in pattern position: enum variant atom match
      # "Active" -> :active, "ChargeSucceeded" -> :charge_succeeded
      atom = variant_pattern_atom(name)
      {:cerl.c_atom(atom), scope}
    else
      # Lowercase identifier: variable binding
      vname = var_name(name)
      {:cerl.c_var(vname), Map.put(scope, name, vname)}
    end
  end

  defp generate_pattern(%AST.Wildcard{}, scope) do
    {:cerl.c_var(gen_var()), scope}
  end

  # Enum variant pattern: Variant(arg1, arg2, ...) or Enum.Variant(arg1, arg2, ...)
  # Compiles to a tuple pattern: {:variant_name, Arg1, Arg2, ...}
  defp generate_pattern(%AST.Call{target: %AST.Identifier{name: name}, args: args}, scope) do
    variant_atom = variant_pattern_atom(name)

    {arg_patterns, final_scope} =
      Enum.reduce(args, {[], scope}, fn arg, {pats, sc} ->
        {pat, new_sc} = generate_pattern(arg, sc)
        {[pat | pats], new_sc}
      end)

    tuple_elements = [:cerl.c_atom(variant_atom) | Enum.reverse(arg_patterns)]
    {:cerl.c_tuple(tuple_elements), final_scope}
  end

  # ------------------------------------------------------------------
  # Interpolation
  # ------------------------------------------------------------------

  # Interpolated expressions reach codegen without a static type (scope maps
  # names to Core Erlang vars only), so the to-string coercion dispatches on
  # the runtime type: binaries pass through; Int/Float/Bool render their
  # canonical text forms (Float via :short, matching Stdlib Float.to_string/1).
  defp interpolation_to_binary(value_expr) do
    var = :cerl.c_var(gen_var())

    type_check = fn predicate ->
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(predicate), [var])
    end

    as_int =
      :cerl.c_call(:cerl.c_atom(:erlang), :cerl.c_atom(:integer_to_binary), [var])

    as_float =
      :cerl.c_call(
        :cerl.c_atom(:erlang),
        :cerl.c_atom(:float_to_binary),
        [var, :cerl.abstract([:short])]
      )

    as_atom =
      :cerl.c_call(
        :cerl.c_atom(:erlang),
        :cerl.c_atom(:atom_to_binary),
        [var, :cerl.c_atom(:utf8)]
      )

    unsupported =
      :cerl.c_call(
        :cerl.c_atom(:erlang),
        :cerl.c_atom(:error),
        [:cerl.c_tuple([:cerl.c_atom(:unsupported_interpolation), var])]
      )

    coerced =
      [
        {:is_binary, var},
        {:is_integer, as_int},
        {:is_float, as_float},
        {:is_atom, as_atom}
      ]
      |> List.foldr(unsupported, fn {predicate, result}, fallback ->
        :cerl.c_case(type_check.(predicate), [
          :cerl.c_clause([:cerl.c_atom(true)], result),
          :cerl.c_clause([:cerl.c_atom(false)], fallback)
        ])
      end)

    :cerl.c_let([var], value_expr, coerced)
  end

  # ------------------------------------------------------------------
  # Capabilities literal for passing to runtime
  # ------------------------------------------------------------------

  defp generate_capabilities_literal(capabilities) do
    caps_list =
      Enum.map(capabilities, fn %AST.Capability{kind: kind, params: params} ->
        param_strings = Enum.map(params, &capability_param_to_string/1)

        kind_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:kind),
            :cerl.abstract(kind)
          )

        params_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:params),
            :cerl.abstract(param_strings)
          )

        :cerl.c_map([kind_pair, params_pair])
      end)

    :cerl.make_list(caps_list)
  end

  # ------------------------------------------------------------------
  # JSON Schema resolution for json[T]
  # ------------------------------------------------------------------

  # Build the JSON Schema for a `json[T]` type parameter. The full
  # declaration map is threaded as the resolution env so SchemaGen can
  # inline nested record/enum-typed fields (rather than emitting a bare
  # `{"type": "object"}`); this is what lets the runtime coerce nested
  # objects to atom keys recursively for both req.json[T] and llm.json[T].
  defp json_schema_for(type_name, type_decls) do
    env = schema_env(type_decls)

    case Map.get(type_decls, type_name) do
      %AST.TypeDecl{} = decl -> SchemaGen.to_json_schema(decl, env)
      %AST.EnumDecl{} = decl -> SchemaGen.enum_to_schema(decl, env)
      _ -> %{}
    end
  end

  # Convert the collected declarations into the tagged env shape SchemaGen
  # expects (`%{name => {:type, decl} | {:enum, decl}}`).
  defp schema_env(type_decls) do
    Map.new(type_decls, fn
      {name, %AST.TypeDecl{} = decl} -> {name, {:type, decl}}
      {name, %AST.EnumDecl{} = decl} -> {name, {:enum, decl}}
    end)
  end

  # ------------------------------------------------------------------
  # Call resolution
  # ------------------------------------------------------------------

  # Resolve a call: if the target looks like a module function, use c_call
  defp generate_call(target_expr, args) do
    # For local function calls (within the same module), use c_apply
    :cerl.c_apply(target_expr, args)
  end

  # ------------------------------------------------------------------
  # Sequence (list of expressions with let-bindings)
  # ------------------------------------------------------------------

  defp generate_sequence([expr], scope) do
    generate_expr(expr, scope)
  end

  defp generate_sequence([%AST.Let{name: name, value: value} | rest], scope) do
    vname = var_name(name)
    new_scope = Map.put(scope, name, vname)
    value_expr = generate_expr(value, scope)
    body = generate_sequence(rest, new_scope)
    :cerl.c_let([:cerl.c_var(vname)], value_expr, body)
  end

  defp generate_sequence([expr | rest], scope) do
    # Non-binding expression in a sequence: evaluate for side effects
    val = generate_expr(expr, scope)
    body = generate_sequence(rest, scope)
    discard_var = :cerl.c_var(gen_var())
    :cerl.c_let([discard_var], val, body)
  end

  # ------------------------------------------------------------------
  # Variable naming: snake_case -> CamelCase
  # ------------------------------------------------------------------

  defp var_name(name) when is_binary(name) do
    name
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
    |> String.to_atom()
  end

  # Generate a unique variable name to avoid conflicts.
  #
  # The counter lives in the process dictionary because threading it through
  # every generate_* function would touch dozens of signatures. It is reset
  # at each generate/1 entry point so state never leaks between compilations
  # and generated names stay deterministic per module. Uniqueness only needs
  # to hold within a single compilation, and a process runs one compilation
  # at a time.
  defp gen_var do
    counter = Process.get(:skein_var_counter, 0)
    Process.put(:skein_var_counter, counter + 1)
    String.to_atom("_skein_#{counter}")
  end

  defp reset_var_counter do
    Process.put(:skein_var_counter, 0)
    :ok
  end

  # ------------------------------------------------------------------
  # Operator mapping
  # ------------------------------------------------------------------

  defp erlang_op(:+), do: :+
  defp erlang_op(:-), do: :-
  defp erlang_op(:*), do: :*
  defp erlang_op(:/), do: :div
  defp erlang_op(:==), do: :==
  defp erlang_op(:!=), do: :"/="
  defp erlang_op(:<), do: :<
  defp erlang_op(:>), do: :>
  defp erlang_op(:<=), do: :"=<"
  defp erlang_op(:>=), do: :>=
  defp erlang_op(:&&), do: :and
  defp erlang_op(:||), do: :or
end
