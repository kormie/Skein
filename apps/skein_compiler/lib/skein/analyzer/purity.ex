defmodule Skein.Analyzer.Purity do
  @moduledoc """
  Purity and provider-contract analyzer passes, extracted verbatim from
  `Skein.Analyzer` (#315).

  - Pass 2g (E0029): `test` bodies and scenario `implement` provider blocks
    must be pure — no capability-gated effect reached directly or
    transitively through local fn calls/references (#273, #295/B6).
  - Pass 2h (E0038/E0020): every scenario `implement` provider block is held
    to its capability's canonical provider contract (#295/B6).

  Shared inference/formatting helpers stay in `Skein.Analyzer` and are
  reached through its `@doc false` seams.
  """

  alias Skein.Analyzer
  alias Skein.AST
  alias Skein.Error

  # namespace => required capability (nil = always available, e.g. trace) —
  # derived from the authoritative effect-ABI registry (C1/#296), the same
  # expression the main analyzer uses.
  @effect_namespaces Skein.EffectABI.effect_namespaces()

  # ------------------------------------------------------------------
  # Pass 2g: Purity of `test` bodies and scenario `implement` providers (#273)
  #
  # `test` is for pure, module-level unit tests — effects belong in `scenario`.
  # Scenario `implement` provider blocks must likewise be pure: they replace an
  # effect, so they cannot themselves perform one. Both are E0029.
  # ------------------------------------------------------------------

  @doc """
  Pass 2g: check that `test` bodies and scenario `implement` provider blocks
  are pure (E0029), following effects transitively through local fns.
  """
  @spec check_pure_contexts([struct()], map()) :: [Error.t()]
  def check_pure_contexts(declarations, env) do
    # Local fn bodies, for the transitive walk (#295 / B6): an effect hidden
    # behind a helper call poisons the pure context just like a direct one.
    fns =
      declarations
      |> Enum.filter(&match?(%AST.Fn{}, &1))
      |> Map.new(fn %AST.Fn{name: name, body: body} -> {name, body} end)

    test_errors =
      declarations
      |> Enum.filter(&match?(%AST.Test{}, &1))
      |> Enum.flat_map(fn %AST.Test{body: body} ->
        body
        |> collect_effect_sites(fns, MapSet.new())
        |> Enum.map(&effect_in_test_error(&1, env))
      end)

    provider_errors =
      declarations
      |> Enum.filter(&match?(%AST.Scenario{}, &1))
      |> Enum.flat_map(fn %AST.Scenario{capabilities: caps} ->
        caps
        |> List.wrap()
        |> Enum.flat_map(&collect_implement_bodies/1)
        |> Enum.flat_map(fn body ->
          body
          |> collect_effect_sites(fns, MapSet.new())
          |> Enum.map(&effect_in_provider_error(&1, env))
        end)
      end)

    test_errors ++ provider_errors
  end

  # All `implement` provider bodies under a capability, including nested ones.
  defp collect_implement_bodies(%AST.Capability{implement: implement, nested: nested}) do
    own = if implement, do: [implement.body], else: []
    own ++ Enum.flat_map(nested || [], &collect_implement_bodies/1)
  end

  defp collect_implement_bodies(_), do: []

  # Capability-gated effect call sites in an expression, transitively through
  # local fn calls and references (#295 / B6): a pure context must not reach an
  # effect either directly or through a helper. `fns` maps local fn names to
  # their bodies; `visited` guards recursion. `trace` is not gated and is
  # therefore allowed. Returns `[{label, meta, via}]` where `via` is the local
  # call chain ([] for a direct effect) and `meta` is the outermost call site —
  # the location inside the pure context itself.
  defp collect_effect_sites(
         %AST.Call{
           target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: method},
           args: args,
           meta: meta
         },
         fns,
         visited
       )
       when method in ["call", "schema"] do
    [{"tool.#{method}", meta, []} | Enum.flat_map(args, &collect_effect_sites(&1, fns, visited))]
  end

  defp collect_effect_sites(
         %AST.Call{
           target: %AST.FieldAccess{subject: %AST.Identifier{name: namespace}, field: method},
           args: args,
           meta: meta
         },
         fns,
         visited
       ) do
    own =
      if Analyzer.effect_namespace?(namespace) and Analyzer.effect_method?(namespace, method) and
           Map.get(@effect_namespaces, namespace) != nil do
        [{"#{namespace}.#{method}", meta, []}]
      else
        []
      end

    own ++ Enum.flat_map(args, &collect_effect_sites(&1, fns, visited))
  end

  # A local fn call: the callee's effect sites poison this context too. The
  # reported location stays the call site in the pure context; the callee (and
  # any deeper hops) accumulate in the via chain.
  defp collect_effect_sites(
         %AST.Call{target: %AST.Identifier{name: fname}, args: args, meta: meta},
         fns,
         visited
       ) do
    Enum.flat_map(args, &collect_effect_sites(&1, fns, visited)) ++
      callee_effect_sites(fname, meta, fns, visited)
  end

  defp collect_effect_sites(%AST.Call{args: args}, fns, visited),
    do: Enum.flat_map(args, &collect_effect_sites(&1, fns, visited))

  # `assert expr` wraps an expression; an effect inside it poisons the pure
  # context (it was previously a synthetic Call whose args were walked).
  defp collect_effect_sites(%AST.Assert{expr: expr}, fns, visited),
    do: collect_effect_sites(expr, fns, visited)

  # A reference to a local fn can be invoked by whatever receives it (stdlib
  # callbacks, process.spawn under test), so it carries the fn's effects.
  defp collect_effect_sites(%AST.FnRef{name: fname, meta: meta}, fns, visited),
    do: callee_effect_sites(fname, meta, fns, visited)

  defp collect_effect_sites(%AST.Block{expressions: exprs}, fns, visited),
    do: Enum.flat_map(exprs, &collect_effect_sites(&1, fns, visited))

  defp collect_effect_sites(%AST.Let{value: value}, fns, visited),
    do: collect_effect_sites(value, fns, visited)

  defp collect_effect_sites(%AST.Match{subject: subject, arms: arms}, fns, visited) do
    collect_effect_sites(subject, fns, visited) ++
      Enum.flat_map(arms, fn %AST.MatchArm{body: body} ->
        collect_effect_sites(body, fns, visited)
      end)
  end

  defp collect_effect_sites(%AST.Pipe{left: left, right: right}, fns, visited),
    do: collect_effect_sites(left, fns, visited) ++ collect_effect_sites(right, fns, visited)

  defp collect_effect_sites(%AST.BinaryOp{left: left, right: right}, fns, visited),
    do: collect_effect_sites(left, fns, visited) ++ collect_effect_sites(right, fns, visited)

  defp collect_effect_sites(%AST.UnaryOp{operand: operand}, fns, visited),
    do: collect_effect_sites(operand, fns, visited)

  defp collect_effect_sites(%AST.FieldAccess{subject: subject}, fns, visited),
    do: collect_effect_sites(subject, fns, visited)

  defp collect_effect_sites(%AST.StringLit{segments: segments}, fns, visited) do
    Enum.flat_map(segments, fn
      {:interpolation, expr} -> collect_effect_sites(expr, fns, visited)
      {:literal, _} -> []
    end)
  end

  defp collect_effect_sites(%AST.MapLit{entries: entries}, fns, visited),
    do: Enum.flat_map(entries, fn {_k, v} -> collect_effect_sites(v, fns, visited) end)

  defp collect_effect_sites(%AST.RecordLit{fields: fields}, fns, visited),
    do: Enum.flat_map(fields, fn {_k, v} -> collect_effect_sites(v, fns, visited) end)

  defp collect_effect_sites(%AST.ListLit{elements: elements}, fns, visited),
    do: Enum.flat_map(elements, &collect_effect_sites(&1, fns, visited))

  defp collect_effect_sites(_, _fns, _visited), do: []

  defp callee_effect_sites(fname, meta, fns, visited) do
    case Map.get(fns, fname) do
      nil ->
        []

      body ->
        if MapSet.member?(visited, fname) do
          []
        else
          body
          |> collect_effect_sites(fns, MapSet.put(visited, fname))
          |> Enum.map(fn {label, _inner_meta, via} -> {label, meta, [fname | via]} end)
        end
    end
  end

  defp via_suffix([]), do: ""
  defp via_suffix(via), do: " (reached via #{Enum.join(via, " -> ")})"

  defp effect_in_test_error({label, meta, via}, env) do
    %Error{
      code: "E0029",
      severity: :error,
      message:
        "Effect '#{label}' is not allowed in a 'test'; 'test' is for pure unit tests — use a 'scenario'" <>
          via_suffix(via),
      location: Analyzer.location_from_meta(meta, env.file),
      context: nil,
      fix_hint:
        "Move this effectful check into a 'scenario', where effects are declared and controlled",
      fix_code: "scenario \"...\" { /* ... */ }"
    }
  end

  defp effect_in_provider_error({label, meta, via}, env) do
    %Error{
      code: "E0029",
      severity: :error,
      message:
        "Effect '#{label}' is not allowed in an 'implement' provider block; providers must be pure" <>
          via_suffix(via),
      location: Analyzer.location_from_meta(meta, env.file),
      context: nil,
      fix_hint: "Return a value directly; a provider replaces an effect and cannot perform one",
      fix_code: nil
    }
  end

  # ------------------------------------------------------------------
  # Pass 2h: Scenario provider contracts (#295 / B6)
  #
  # A provider replaces a specific effect, so its signature is fixed by the
  # capability it controls — the runtime invokes it positionally with exactly
  # these argument and result shapes. Mirrors the runtime resolution sites
  # (`Skein.Runtime.Nondeterminism`, `Skein.Runtime.Http.dispatch/3`,
  # `Skein.Runtime.Llm.ProviderBackend`). A capability kind outside this table
  # has no runtime resolution point, so an `implement` block under it would be
  # silently dead — that is a contract error, not a no-op.
  # ------------------------------------------------------------------

  # Derived from the effect-ABI registry (C1/#296).
  @provider_contracts Skein.EffectABI.provider_contracts()

  @doc """
  Pass 2h: check every scenario `implement` provider block against its
  capability's canonical provider contract (E0038) and type-check its body
  against the declared return type (E0020).
  """
  @spec check_provider_contracts([struct()], map()) :: [Error.t()]
  def check_provider_contracts(declarations, env) do
    declarations
    |> Enum.filter(&match?(%AST.Scenario{}, &1))
    |> Enum.flat_map(fn %AST.Scenario{capabilities: caps} ->
      caps |> List.wrap() |> Enum.flat_map(&check_envelope_providers(&1, env))
    end)
  end

  defp check_envelope_providers(
         %AST.Capability{kind: kind, implement: implement, nested: nested},
         env
       ) do
    own = if implement, do: check_provider(kind, implement, env), else: []
    own ++ Enum.flat_map(nested || [], &check_envelope_providers(&1, env))
  end

  defp check_envelope_providers(_, _env), do: []

  defp check_provider(kind, %AST.CapabilityImplement{} = implement, env) do
    case Map.get(@provider_contracts, kind) do
      nil ->
        [unsupported_provider_error(kind, implement, env)]

      contract ->
        provider_signature_errors(kind, contract, implement, env) ++
          provider_body_errors(implement, env)
    end
  end

  defp provider_signature_errors(kind, contract, %AST.CapabilityImplement{} = implement, env) do
    declared_params =
      Enum.map(implement.params, fn %AST.Field{type: type} ->
        Analyzer.resolve_type(type, env.types)
      end)

    declared_return = Analyzer.resolve_type(implement.return_type, env.types)

    contract_params = Enum.map(contract.params, &Analyzer.normalize_enum_refs(&1, env))
    contract_return = Analyzer.normalize_enum_refs(contract.return, env)

    if declared_params == contract_params and declared_return == contract_return do
      []
    else
      [
        %Error{
          code: "E0038",
          severity: :error,
          message:
            "Provider for capability '#{kind}' must be '#{contract.signature}', got 'implement(#{format_provider_params(implement.params, env)}) -> #{Analyzer.format_type(declared_return)}'",
          location: Analyzer.location_from_meta(implement.meta, env.file),
          context: "the runtime invokes the provider with exactly this contract",
          fix_hint: "Match the provider contract for '#{kind}' exactly",
          fix_code: contract.signature
        }
      ]
    end
  end

  defp unsupported_provider_error(kind, %AST.CapabilityImplement{meta: meta}, env) do
    supported = @provider_contracts |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    %Error{
      code: "E0038",
      severity: :error,
      message: "Capability '#{kind}' does not support an 'implement' provider",
      location: Analyzer.location_from_meta(meta, env.file),
      context: "no runtime resolution point exists for '#{kind}', so this provider would be dead",
      fix_hint:
        "Providers exist for: #{supported}. Other effects are controlled by replay or the test-runner default policy",
      fix_code: nil
    }
  end

  # The provider body is executable and typed: run full inference with the
  # declared params in scope and hold the body to the declared return type,
  # exactly like a named fn body (E0020 + the #291 boundary guard).
  defp provider_body_errors(
         %AST.CapabilityImplement{params: params, return_type: ret, body: body, meta: meta},
         env
       ) do
    declared_return = Analyzer.resolve_type(ret, env.types)

    vars =
      Map.new(params, fn %AST.Field{name: name, type: type} ->
        {name, Analyzer.resolve_type(type, env.types)}
      end)

    body_env = %{env | variables: vars, current_fn_return_type: declared_return}
    {actual_return, errors} = Analyzer.infer_type(body, body_env)

    return_errors =
      if Analyzer.types_compatible?(actual_return, declared_return) do
        Analyzer.boundary_type_errors(actual_return, declared_return, meta, env)
      else
        [
          %Error{
            code: "E0020",
            severity: :error,
            message:
              "Provider return type mismatch: expected #{Analyzer.format_type(declared_return)}, got #{Analyzer.format_type(actual_return)}",
            location: Analyzer.location_from_meta(meta, env.file),
            fix_hint: "Make the provider body produce #{Analyzer.format_type(declared_return)}",
            fix_code: nil
          }
        ]
      end

    errors ++ return_errors
  end

  defp format_provider_params(params, env) do
    params
    |> Enum.map(fn %AST.Field{name: name, type: type} ->
      "#{name}: #{Analyzer.format_type(Analyzer.resolve_type(type, env.types))}"
    end)
    |> Enum.join(", ")
  end
end
