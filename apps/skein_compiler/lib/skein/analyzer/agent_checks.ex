defmodule Skein.Analyzer.AgentChecks do
  @moduledoc """
  Agent-specific analyzer passes, extracted verbatim from `Skein.Analyzer`
  (#315).

  - Phase transition validation (E0030) and unreachable phases (E0031).
  - Phase handler coverage (E0032).
  - `transition()` call validation against the declared Phase enum
    (E0030/E0033).
  - Agent-only lifecycle constructs outside agents: `transition()` E0033,
    `suspend()` E0034, `stop()` E0036, `emit` E0039.

  Shared helpers (error-location plumbing, name suggestions) stay in
  `Skein.Analyzer` and are reached through its `@doc false` seams.
  """

  alias Skein.Analyzer
  alias Skein.AST
  alias Skein.Error

  # ------------------------------------------------------------------
  # Phase transition validation
  # ------------------------------------------------------------------

  @doc """
  Validate that every declared phase transition targets a known Phase
  variant (E0030) and warn on unreachable phases (E0031).
  """
  @spec validate_phase_transitions(AST.Agent.t(), map()) :: [Error.t()]
  def validate_phase_transitions(%AST.Agent{phases: nil}, _env), do: []

  def validate_phase_transitions(
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
              location: Analyzer.location_from_meta(vmeta, env.file),
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
            location: Analyzer.location_from_meta(meta, env.file),
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

  @doc """
  Check that every Phase variant has an `on phase(...)` handler (E0032).
  """
  @spec check_phase_handlers(AST.Agent.t(), map()) :: [Error.t()]
  def check_phase_handlers(%AST.Agent{phases: nil}, _env), do: []

  def check_phase_handlers(
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
            location: Analyzer.location_from_meta(meta, env.file),
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

  @doc """
  Validate `transition()` calls in handler bodies against the declared
  Phase enum and its transition table (E0030/E0033).
  """
  @spec validate_transition_calls(AST.Agent.t(), map()) :: [Error.t()]
  def validate_transition_calls(%AST.Agent{phases: nil, handlers: handlers}, env) do
    # If there are no phases but there are transition calls, that's an error
    transitions = collect_transitions_from_handlers(handlers)

    Enum.map(transitions, fn {_phase, tmeta} ->
      %Error{
        code: "E0033",
        severity: :error,
        message: "transition() used but no Phase enum is defined in this agent",
        location: Analyzer.location_from_meta(tmeta, env.file),
        fix_hint: "Define an 'enum Phase { ... }' in the agent",
        fix_code: "enum Phase { Start -> [] }"
      }
    end)
  end

  def validate_transition_calls(
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
                location: Analyzer.location_from_meta(tmeta, env.file),
                fix_hint: "Use a valid Phase variant name",
                fix_code:
                  "transition(Phase.#{Analyzer.closest_name(target_phase, MapSet.to_list(variant_names))})"
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
                  location: Analyzer.location_from_meta(tmeta, env.file),
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
  # Agent-only lifecycle calls outside agent handlers:
  # E0033 transition(), E0034 suspend(), E0036 stop()
  # ------------------------------------------------------------------

  @doc """
  Reject agent-only lifecycle constructs outside agent handlers:
  `transition()` E0033, `suspend()` E0034, `stop()` E0036, `emit` E0039.
  """
  @spec check_agent_only_calls([struct()], map()) :: [Error.t()]
  def check_agent_only_calls(declarations, env) do
    declarations
    |> Enum.flat_map(fn
      %AST.Fn{body: body} -> collect_agent_only_calls(body)
      %AST.Handler{body: body} -> collect_agent_only_calls(body)
      %AST.ToolDecl{implement: body} -> collect_agent_only_calls(body)
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
      location: Analyzer.location_from_meta(meta, env.file),
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
      location: Analyzer.location_from_meta(meta, env.file),
      fix_hint: "Move this to an agent handler (on start/on phase)",
      fix_code: "on phase(Phase.Name) -> { suspend(\"reason\") }"
    }
  end

  defp agent_only_call_error(:stop, meta, env) do
    %Error{
      code: "E0036",
      severity: :error,
      message: "stop() can only be used in agent handlers, not in module functions or handlers",
      location: Analyzer.location_from_meta(meta, env.file),
      fix_hint: "Move this to an agent handler (on start/on phase)",
      fix_code: "on phase(Phase.Name) -> { stop() }"
    }
  end

  defp agent_only_call_error(:emit, meta, env) do
    %Error{
      code: "E0039",
      severity: :error,
      message: "emit can only be used in agent handlers, not in module functions or handlers",
      location: Analyzer.location_from_meta(meta, env.file),
      fix_hint:
        "Move the emit into an agent handler (on start/on phase); " <>
          "outside agents, record events with event.log(name, data)",
      fix_code: nil
    }
  end

  defp collect_agent_only_calls(%AST.Transition{meta: meta}), do: [{:transition, meta}]
  defp collect_agent_only_calls(%AST.Suspend{meta: meta}), do: [{:suspend, meta}]
  defp collect_agent_only_calls(%AST.Stop{meta: meta}), do: [{:stop, meta}]
  defp collect_agent_only_calls(%AST.Emit{meta: meta}), do: [{:emit, meta}]

  defp collect_agent_only_calls(%AST.Block{expressions: exprs}),
    do: Enum.flat_map(exprs, &collect_agent_only_calls/1)

  defp collect_agent_only_calls(%AST.Match{arms: arms}) do
    Enum.flat_map(arms, fn %AST.MatchArm{body: body} -> collect_agent_only_calls(body) end)
  end

  defp collect_agent_only_calls(%AST.Let{value: value}), do: collect_agent_only_calls(value)
  defp collect_agent_only_calls(_), do: []
end
