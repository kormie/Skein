defmodule Skein.Runtime.SupervisorHost do
  @moduledoc """
  Boots real OTP supervisors from compiled `supervisor` declarations (#325).

  A Skein module's `supervisor` declarations compile to `__supervisors__/0`
  metadata. This module reads that metadata and starts one OTP `Supervisor`
  per declaration:

  - each `child Target` resolves to the compiled nested-agent module
    (`Skein.Agent.<ModuleName>.<Target>`) and is started via
    `Skein.Runtime.Agent.start_link/2`
  - the declared `strategy:` is passed through (default `one_for_one`)
  - the declared `max_restarts: N per M s` becomes OTP restart intensity
    (`max_restarts`/`max_seconds`); when omitted, OTP defaults apply
  - a child's brace-block options are its start arguments (the map handed
    to the agent's `on start(...)`), except `restart:`, which selects the
    OTP restart policy (`permanent` default, `transient`, `temporary`)

  Every successful child start — including every restart, since the
  supervisor re-runs `start_child/3` — appends a
  `%{kind: :supervisor, event: :child_started, ...}` event to the
  EventStore, so restarts are visible in the trace. A child whose target
  does not resolve to a compiled agent is skipped with a
  `:child_skipped` event rather than crashing the boot.

  Supervisors are started with `Supervisor.start_link/2`, so they are
  linked to the caller: under `skein run` they live exactly as long as
  the `Skein.Runtime.Server` process that boots them.
  """

  alias Skein.Runtime.EventStore

  @agent_prefix "Elixir.Skein.Agent."
  @user_prefix "Elixir.Skein.User."

  @doc """
  Starts an OTP supervisor for every `supervisor` declaration in the
  compiled module `mod`.

  Returns `{:ok, pids}` with one pid per declaration (linked to the
  caller), or `{:ok, []}` when the module declares no supervisors.
  """
  @spec start_supervisors(module()) :: {:ok, [pid()]}
  def start_supervisors(mod) do
    if function_exported?(mod, :__supervisors__, 0) do
      pids = Enum.map(mod.__supervisors__(), &start_declared_supervisor(mod, &1))
      {:ok, pids}
    else
      {:ok, []}
    end
  end

  @doc """
  Child-start shim used in generated child specs. Delegates to
  `Skein.Runtime.Agent.start_link/2` and appends a `:child_started`
  EventStore event on success — every supervisor restart re-runs this,
  so restart #2+ appear as additional `:child_started` events.
  """
  @spec start_child(module(), map(), %{supervisor: String.t(), child: String.t()}) ::
          {:ok, pid()} | {:error, term()} | :ignore
  def start_child(agent_module, args_map, %{supervisor: supervisor_name, child: child_name}) do
    case Skein.Runtime.Agent.start_link(agent_module, args_map) do
      {:ok, pid} ->
        EventStore.append(%{
          kind: :supervisor,
          event: :child_started,
          supervisor: supervisor_name,
          child: child_name,
          agent_module: agent_module,
          pid: inspect(pid)
        })

        {:ok, pid}

      other ->
        other
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp start_declared_supervisor(mod, declaration) do
    children =
      declaration.children
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} -> child_spec(mod, declaration, child, index) end)

    options =
      [strategy: declaration.strategy || :one_for_one] ++
        intensity_options(declaration.max_restarts)

    {:ok, pid} = Supervisor.start_link(children, options)
    pid
  end

  # Declared `max_restarts: N per M s` -> OTP intensity; absent -> OTP defaults.
  defp intensity_options({count, period}), do: [max_restarts: count, max_seconds: period]
  defp intensity_options(nil), do: []

  defp child_spec(mod, declaration, %{target: target, options: options}, index) do
    case resolve_agent_module(mod, target) do
      {:ok, agent_module} ->
        options = options || %{}

        [
          %{
            id: {declaration.name, target, index},
            start:
              {__MODULE__, :start_child,
               [
                 agent_module,
                 Map.drop(options, [:restart]),
                 %{supervisor: declaration.name, child: target}
               ]},
            restart: restart_policy(options)
          }
        ]

      :error ->
        EventStore.append(%{
          kind: :supervisor,
          event: :child_skipped,
          supervisor: declaration.name,
          child: target,
          reason: :no_such_agent
        })

        []
    end
  end

  # A nested agent in module `Mod` compiles to Skein.Agent.<Mod's short
  # name>.<Target>; the short name is the compiled module atom minus its
  # Skein.User namespace. Resolution is by that naming convention plus a
  # loaded-module check — there is no separate agent registry.
  defp resolve_agent_module(mod, target) do
    short_name =
      mod
      |> Atom.to_string()
      |> String.replace_prefix(@user_prefix, "")
      |> String.replace_prefix("Elixir.", "")

    agent_module = String.to_atom("#{@agent_prefix}#{short_name}.#{target}")

    if Code.ensure_loaded?(agent_module) and
         function_exported?(agent_module, :__start_handler__, 2) do
      {:ok, agent_module}
    else
      :error
    end
  end

  # Declared child restart policy (`{ restart: permanent | transient |
  # temporary }`) -> the OTP restart mode; `permanent` when undeclared.
  defp restart_policy(%{restart: "transient"}), do: :transient
  defp restart_policy(%{restart: "temporary"}), do: :temporary
  defp restart_policy(_options), do: :permanent
end
