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

  # Known effect namespaces and their runtime modules
  @effect_runtime_modules %{
    "http" => :"Elixir.Skein.Runtime.Http"
  }

  @spec generate(AST.Module.t()) :: {:ok, binary()} | {:error, [Error.t()]}
  def generate(%AST.Module{} = ast) do
    module_atom = String.to_atom("Elixir.Skein.User.#{ast.name}")

    # Extract capabilities for embedding in the module
    capabilities =
      ast.declarations
      |> Enum.filter(&match?(%AST.Capability{}, &1))

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

    # Build exports and function definitions for regular functions
    fn_exports =
      Enum.map(fns, fn f -> :cerl.c_fname(String.to_atom(f.name), length(f.params)) end)

    fn_defs =
      Enum.map(fns, fn f ->
        fname = :cerl.c_fname(String.to_atom(f.name), length(f.params))
        fun = generate_fn(f, capabilities, fn_arities)
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
        fun = generate_handler_fn(handler, capabilities, fn_arities)
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

    all_exports =
      [info_fname, caps_fname, handlers_fname | fn_exports] ++ handler_exports

    all_defs =
      [
        {info_fname, info_fun},
        {caps_fname, caps_fun},
        {handlers_fname, handlers_fun}
        | fn_defs
      ] ++ handler_defs

    mod =
      :cerl.c_module(
        :cerl.c_atom(module_atom),
        all_exports,
        [],
        all_defs
      )

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
             location: %{file: ast.meta.file, line: 1, col: 1}
           }
         ]}
    end
  end

  # ------------------------------------------------------------------
  # Function generation
  # ------------------------------------------------------------------

  defp generate_fn(%AST.Fn{params: params, body: body}, capabilities, fn_arities) do
    # Create variable bindings for params
    param_vars = Enum.map(params, fn %AST.Field{name: name} -> :cerl.c_var(var_name(name)) end)

    # Build initial scope from params
    scope =
      params
      |> Enum.map(fn %AST.Field{name: name} -> {name, var_name(name)} end)
      |> Map.new()
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)

    body_expr = generate_expr(body, scope)
    :cerl.c_fun(param_vars, body_expr)
  end

  # ------------------------------------------------------------------
  # Handler generation
  # ------------------------------------------------------------------

  defp handler_fn_name(index) do
    String.to_atom("__handler_#{index}__")
  end

  defp generate_handler_fn(%AST.Handler{param: param, body: body}, capabilities, fn_arities) do
    # Handler takes a single request map argument
    req_var = :cerl.c_var(var_name(param))

    scope =
      %{param => var_name(param)}
      |> Map.put(:__capabilities__, capabilities)
      |> Map.put(:__fn_arities__, fn_arities)

    body_expr = generate_expr(body, scope)
    :cerl.c_fun([req_var], body_expr)
  end

  # Generate __handlers__/0 function that returns handler metadata
  defp generate_handlers_meta_fn(handlers) do
    handlers_list =
      handlers
      |> Enum.map(fn {%AST.Handler{method: method, route: route}, index} ->
        method_pair =
          :cerl.c_map_pair(
            :cerl.c_atom(:method),
            :cerl.c_atom(String.to_atom(method))
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

        :cerl.c_map([method_pair, route_pair, fn_pair])
      end)
      |> :cerl.make_list()

    :cerl.c_fun([], handlers_list)
  end

  # Generate __capabilities__/0 function that returns capability metadata as a list of maps
  defp generate_capabilities_fn(capabilities) do
    caps_list =
      capabilities
      |> Enum.map(fn %AST.Capability{kind: kind, params: params} ->
        param_strings =
          Enum.map(params, fn
            %AST.StringLit{segments: [{:literal, text}]} -> text
            %AST.StringLit{segments: []} -> ""
            _ -> ""
          end)

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
    :cerl.c_case(subject_expr, clauses)
  end

  # Binary operations
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
  # Threads left as first argument to right
  defp generate_expr(%AST.Pipe{left: left, right: right}, scope) do
    left_expr = generate_expr(left, scope)

    case right do
      %AST.Call{target: target, args: args} ->
        right_target = generate_expr(target, scope)
        right_args = [left_expr | Enum.map(args, &generate_expr(&1, scope))]
        generate_call(right_target, right_args)

      _ ->
        # If the right side is just a function reference, apply it
        right_expr = generate_expr(right, scope)
        :cerl.c_apply(right_expr, [left_expr])
    end
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
       when method in ["get", "put", "delete", "query"] do
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
    # String with interpolation: build iolist and call erlang:iolist_to_binary/1
    parts =
      Enum.map(segments, fn
        {:literal, text} ->
          :cerl.abstract(text)

        {:interpolation, interp_token} ->
          generate_interpolation(interp_token, scope)
      end)

    iolist = :cerl.make_list(parts)

    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:iolist_to_binary),
      [iolist]
    )
  end

  # Identifier
  defp generate_expr(%AST.Identifier{name: name}, scope) do
    case Map.get(scope, name) do
      nil ->
        # Could be a module reference or unresolved - use the raw name
        :cerl.c_var(var_name(name))

      var ->
        :cerl.c_var(var)
    end
  end

  # FnRef
  defp generate_expr(%AST.FnRef{name: name}, _scope) do
    :cerl.c_var(var_name(name))
  end

  # ------------------------------------------------------------------
  # Match arm generation
  # ------------------------------------------------------------------

  defp generate_match_arm(%AST.MatchArm{pattern: pattern, body: body}, scope) do
    {pat, new_scope} = generate_pattern(pattern, scope)
    body_expr = generate_expr(body, new_scope)
    :cerl.c_clause([pat], body_expr)
  end

  defp generate_pattern(%AST.BoolLit{value: value}, scope) do
    {:cerl.c_atom(value), scope}
  end

  defp generate_pattern(%AST.IntLit{value: value}, scope) do
    {:cerl.c_int(value), scope}
  end

  defp generate_pattern(%AST.StringLit{segments: [{:literal, text}]}, scope) do
    {:cerl.abstract(text), scope}
  end

  defp generate_pattern(%AST.Identifier{name: name}, scope) do
    vname = var_name(name)
    {:cerl.c_var(vname), Map.put(scope, name, vname)}
  end

  defp generate_pattern(%AST.Wildcard{}, scope) do
    {:cerl.c_var(gen_var()), scope}
  end

  # ------------------------------------------------------------------
  # Interpolation
  # ------------------------------------------------------------------

  defp generate_interpolation({:ident, _, name}, scope) do
    case Map.get(scope, name) do
      nil -> :cerl.c_var(var_name(name))
      var -> :cerl.c_var(var)
    end
  end

  defp generate_interpolation({:field_access, subject, field}, scope) do
    subj = generate_interpolation(subject, scope)

    :cerl.c_call(
      :cerl.c_atom(:erlang),
      :cerl.c_atom(:map_get),
      [:cerl.c_atom(String.to_atom(field)), subj]
    )
  end

  # ------------------------------------------------------------------
  # Capabilities literal for passing to runtime
  # ------------------------------------------------------------------

  defp generate_capabilities_literal(capabilities) do
    caps_list =
      Enum.map(capabilities, fn %AST.Capability{kind: kind, params: params} ->
        param_strings =
          Enum.map(params, fn
            %AST.StringLit{segments: [{:literal, text}]} -> text
            %AST.StringLit{segments: []} -> ""
            _ -> ""
          end)

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

  # Generate a unique variable name to avoid conflicts
  defp gen_var do
    counter = Process.get(:skein_var_counter, 0)
    Process.put(:skein_var_counter, counter + 1)
    String.to_atom("_skein_#{counter}")
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
