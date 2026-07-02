defmodule Skein.Analyzer.Warnings do
  @moduledoc """
  Warning passes, extracted verbatim from `Skein.Analyzer` (#315).

  - W0001: unused `let` bindings in fn bodies.
  - W0002: declared capabilities never exercised by an effect call/handler.
  - W0004: value-level exhaustiveness — a variant arm with literal field
    patterns only covers those specific values (called from the main
    analyzer's exhaustiveness pass).

  Shared helpers (error-location plumbing, effect-namespace predicates) stay
  in `Skein.Analyzer` and are reached through its `@doc false` seams.
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

  # Value-level exhaustiveness (W0004): a variant arm with literal field
  # patterns only covers those specific values — without a wildcard arm or
  # an all-bindings arm for the same variant, other values of that variant
  # raise case_clause at runtime. Only called when no wildcard arm exists.
  @doc """
  W0004: a variant arm with literal field patterns only covers those
  specific values — warn unless an all-bindings arm covers the variant.
  Called from the main analyzer's exhaustiveness pass when no wildcard
  arm exists.
  """
  @spec value_level_warnings(String.t(), [AST.MatchArm.t()], map()) :: [Error.t()]
  def value_level_warnings(enum_name, arms, env) do
    arms
    |> Enum.filter(&match?(%AST.MatchArm{pattern: %AST.Call{target: %AST.Identifier{}}}, &1))
    |> Enum.group_by(fn %AST.MatchArm{
                          pattern: %AST.Call{target: %AST.Identifier{name: name}}
                        } ->
      Analyzer.strip_enum_prefix(name, enum_name)
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
            location: Analyzer.location_from_meta(pattern_meta, env.file),
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
  # W0001: Unused binding detection
  # ------------------------------------------------------------------

  @doc """
  W0001: warn on `let` bindings that are never referenced (unless prefixed
  with `_`).
  """
  @spec check_unused_bindings_in_declarations([struct()], map()) :: [Error.t()]
  def check_unused_bindings_in_declarations(declarations, _env) do
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
        span = Analyzer.span_from_meta(name_meta, name)

        [
          %Error{
            code: "W0001",
            severity: :warning,
            message: "Unused binding '#{name}'",
            location: Analyzer.location_from_meta(meta, Map.get(fn_meta, :file, "unknown")),
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

  # `assert expr` references whatever its expression references — a binding
  # used only inside an assert is not unused.
  defp collect_referenced_identifiers(%AST.Assert{expr: expr}) do
    collect_referenced_identifiers(expr)
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

  @doc """
  W0002: warn on declared capabilities never exercised by an effect call or
  handler.
  """
  @spec check_unused_capabilities([struct()], map()) :: [Error.t()]
  def check_unused_capabilities(declarations, env) do
    # Collect all effect calls/handlers to determine which capabilities are exercised
    used_capabilities = collect_used_capabilities(declarations, env)

    env.capabilities
    |> Enum.flat_map(fn %AST.Capability{kind: kind, meta: meta} ->
      if kind in used_capabilities do
        []
      else
        span = Analyzer.span_from_meta(meta, "capability")

        [
          %Error{
            code: "W0002",
            severity: :warning,
            message: "Unused capability '#{kind}' — declared but never exercised",
            location: Analyzer.location_from_meta(meta, env.file),
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
        cap = Analyzer.handler_required_capability(source)

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
      if Analyzer.effect_namespace?(namespace) and Analyzer.effect_method?(namespace, method) do
        [namespace]
      else
        []
      end

    ns ++ Enum.flat_map(args, &collect_effect_namespaces/1)
  end

  defp collect_effect_namespaces(%AST.Call{args: args}) do
    Enum.flat_map(args, &collect_effect_namespaces/1)
  end

  # `assert expr` wraps an expression; effect calls inside it exercise their
  # capability (it was previously a synthetic Call whose args were walked).
  defp collect_effect_namespaces(%AST.Assert{expr: expr}) do
    collect_effect_namespaces(expr)
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
end
