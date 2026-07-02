defmodule Skein.Analyzer.Capabilities do
  @moduledoc """
  Capability-checking analyzer pass (Pass 3), extracted verbatim from
  `Skein.Analyzer` (#315).

  Walks fn/handler bodies for effect calls and verifies each against the
  declared capabilities: E0012 (missing capability), E0014 (tool not in any
  `tool.use` envelope), E0015 (duplicate short tool names), E0017 (duplicate
  scoped capabilities), and E0043 (invalid `store.table` declarations).

  Shared helpers (`effect_namespace?/1`, tool-name extraction, error-location
  plumbing) stay in `Skein.Analyzer` and are reached through its `@doc false`
  seams.
  """

  alias Skein.Analyzer
  alias Skein.AST
  alias Skein.Error

  # Registry-derived effect tables (C1/#296) — the same expressions the main
  # analyzer uses; the authoritative shapes live in `Skein.EffectABI`.

  # namespace => required capability (nil = always available, e.g. trace)
  @effect_namespaces Skein.EffectABI.effect_namespaces()

  # Store operations: store.<table>.<method>(...)
  @store_methods Skein.EffectABI.store_methods()

  # ------------------------------------------------------------------
  # Pass 3: Capability checking
  # ------------------------------------------------------------------

  @doc """
  Pass 3: verify effect calls in fn/handler bodies against the declared
  capabilities, plus the module-level duplicate/declaration checks
  (E0012/E0014/E0015/E0017/E0043).
  """
  @spec check_capabilities([struct()], map()) :: [Error.t()]
  def check_capabilities(declarations, env) do
    # Check for duplicate short tool names across all tool.use capabilities,
    # and duplicate declarations of single-label (scoped) capability kinds
    dup_errors =
      check_duplicate_tool_short_names(env) ++
        check_duplicate_scoped_capabilities(env) ++
        check_store_table_declarations(env)

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
    tool_name = Analyzer.extract_tool_name_from_expr(first_arg)

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
      if Analyzer.effect_namespace?(namespace) and Analyzer.effect_method?(namespace, method) do
        check_effect_capability(namespace, method, meta, env)
      else
        []
      end

    own ++ Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  defp collect_effect_calls(%AST.Call{args: args}, env) do
    Enum.flat_map(args, &collect_effect_calls(&1, env))
  end

  # `assert expr` wraps an expression; effect calls inside it need
  # capabilities just like anywhere else (it was previously a synthetic
  # Call whose args were walked).
  defp collect_effect_calls(%AST.Assert{expr: expr}, env) do
    collect_effect_calls(expr, env)
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
      span = Analyzer.capability_insertion_span(env)

      [
        %Error{
          code: "E0012",
          severity: :error,
          message:
            "Capability '#{required_capability}' required but not declared. " <>
              "Effect calls to '#{namespace}' require this capability.",
          location: Analyzer.location_from_meta(meta, env.file),
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
      span = Analyzer.capability_insertion_span(env)

      [
        %Error{
          code: "E0012",
          severity: :error,
          message:
            "Capability 'store.table(\"#{table_name}\")' required but not declared. " <>
              "Store operations on '#{table_name}' require this capability.",
          location: Analyzer.location_from_meta(meta, env.file),
          fix_hint:
            "Add a capability declaration to the module: capability store.table(\"#{table_name}\")",
          fix_code: "capability store.table(\"#{table_name}\")",
          span: span,
          edit_kind: if(span, do: :insert_line)
        }
      ]
    end
  end

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
      |> Enum.map(&Analyzer.extract_tool_name_from_param/1)
      |> Enum.reject(&is_nil/1)
    end)
  end

  # Check that a tool.call/tool.schema references a tool declared in capability tool.use params
  defp check_tool_capability(tool_name, _method, meta, env) do
    declared_names = collect_declared_tool_names(env)

    span = Analyzer.capability_insertion_span(env)

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
            location: Analyzer.location_from_meta(meta, env.file),
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
            location: Analyzer.location_from_meta(meta, env.file),
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
            location: Analyzer.location_from_meta(cap_meta, env.file),
            fix_hint: "Rename one of the tools to avoid the naming conflict",
            fix_code: nil
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

  # Typed store tables (C5/#255, E0043): every `capability store.table(...)`
  # must name BOTH the table and its record type — a declared `type` with
  # exactly one `@primary` field (the get/delete key). Checked per scope's
  # own declarations (nested agents check their own).
  defp check_store_table_declarations(env) do
    env
    |> Map.get(:own_capabilities, env.capabilities)
    |> Enum.filter(&match?(%AST.Capability{kind: "store.table"}, &1))
    |> Enum.flat_map(&store_table_declaration_errors(&1, env))
  end

  defp store_table_declaration_errors(%AST.Capability{params: params, meta: meta}, env) do
    case params do
      [%AST.StringLit{segments: [literal: table]}, %AST.Identifier{name: type_name}] ->
        case Map.get(env.types, type_name) do
          %AST.TypeDecl{} = decl ->
            primary_count =
              Enum.count(decl.fields, fn %AST.Field{annotations: annotations} ->
                Enum.any?(annotations || [], &match?(%AST.Annotation{name: "primary"}, &1))
              end)

            if primary_count == 1 do
              []
            else
              [
                store_table_error(
                  "Record type '#{type_name}' for store table \"#{table}\" must have exactly one @primary field, found #{primary_count}",
                  "Annotate the primary-key field: id: Uuid @primary",
                  nil,
                  meta,
                  env
                )
              ]
            end

          _ ->
            [
              store_table_error(
                "Record type '#{type_name}' for store table \"#{table}\" is not a declared type",
                "Declare the record type this table stores",
                "type #{type_name} { id: Uuid @primary }",
                meta,
                env
              )
            ]
        end

      [%AST.StringLit{segments: [literal: table]} | _] ->
        [
          store_table_error(
            "capability store.table(\"#{table}\") must also name the table's record type (store tables are typed)",
            "Add the record type: capability store.table(\"#{table}\", RecordType)",
            "capability store.table(\"#{table}\", RecordType)",
            meta,
            env
          )
        ]

      _ ->
        [
          store_table_error(
            "capability store.table requires a table name string and a record type",
            "Declare as: capability store.table(\"table_name\", RecordType)",
            "capability store.table(\"table_name\", RecordType)",
            meta,
            env
          )
        ]
    end
  end

  defp store_table_error(message, fix_hint, fix_code, meta, env) do
    %Error{
      code: "E0043",
      severity: :error,
      message: message,
      location: Analyzer.location_from_meta(meta, env.file),
      fix_hint: fix_hint,
      fix_code: fix_code
    }
  end

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
            location: Analyzer.location_from_meta(cap.meta, env.file),
            fix_hint:
              "Remove this declaration or merge its uses into " <>
                "#{kind}(#{inspect(first_label)})",
            fix_code: nil
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
end
