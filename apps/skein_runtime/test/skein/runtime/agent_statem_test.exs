defmodule Skein.Runtime.AgentStatemTest do
  @moduledoc """
  PropCheck stateful (state machine) test for Skein.Runtime.Agent.

  Tests the agent query API (get_phase, get_state, get_events) against
  compiled agents that park in a keep-state phase, allowing us to
  interleave start and query operations in random sequences.

  The model tracks which agents are alive and what their expected
  state is based on the Skein source they were compiled from.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.Agent, as: RuntimeAgent

  # ------------------------------------------------------------------
  # Compile test agents at module load time so they're available
  # during PropCheck generation phase (before forall body runs).
  # ------------------------------------------------------------------

  @parking_source """
  agent StateParkAgent {
    enum Phase {
      Waiting -> []
    }

    on start() -> {
      transition(Phase.Waiting)
    }

    on phase(Phase.Waiting) -> {
      42
    }
  }
  """

  @two_phase_source """
  agent StateTwoPhaseAgent {
    enum Phase {
      Init -> [Active]
      Active -> []
    }

    on start() -> {
      transition(Phase.Init)
    }

    on phase(Phase.Init) -> {
      transition(Phase.Active)
    }

    on phase(Phase.Active) -> {
      42
    }
  }
  """

  @stopping_source """
  agent StateStopAgent {
    enum Phase {
      Done -> []
    }

    on start() -> {
      transition(Phase.Done)
    }

    on phase(Phase.Done) -> {
      stop()
    }
  }
  """

  # Compile at module load so atoms are available during PropCheck generation phase
  @parking_mod elem(Skein.Compiler.compile_string(@parking_source), 1)
  @two_phase_mod elem(Skein.Compiler.compile_string(@two_phase_source), 1)
  @stopping_mod elem(Skein.Compiler.compile_string(@stopping_source), 1)

  # ------------------------------------------------------------------
  # Model state: %{agents: [{pid, expected_phase, expected_alive}]}
  # ------------------------------------------------------------------

  def initial_state do
    %{agents: []}
  end

  # ------------------------------------------------------------------
  # Command generation — uses module attributes (available at compile time)
  # ------------------------------------------------------------------

  def command(state) do
    start_cmds = [
      {:call, __MODULE__, :do_start_parking, []},
      {:call, __MODULE__, :do_start_two_phase, []},
      {:call, __MODULE__, :do_start_stopping, []}
    ]

    alive_agents =
      state.agents
      |> Enum.filter(fn {_pid, _phase, alive} -> alive end)

    query_cmds =
      case alive_agents do
        [] ->
          []

        agents ->
          pids = Enum.map(agents, fn {pid, _phase, _alive} -> pid end)

          [
            {:call, __MODULE__, :do_get_phase, [oneof(pids)]},
            {:call, __MODULE__, :do_get_state, [oneof(pids)]},
            {:call, __MODULE__, :do_get_events, [oneof(pids)]},
            {:call, __MODULE__, :do_stop, [oneof(pids)]}
          ]
      end

    oneof(start_cmds ++ query_cmds)
  end

  # ------------------------------------------------------------------
  # Command implementations
  # ------------------------------------------------------------------

  def do_start_parking do
    {:ok, pid} = RuntimeAgent.start_link(@parking_mod, %{})
    Process.sleep(10)
    pid
  end

  def do_start_two_phase do
    {:ok, pid} = RuntimeAgent.start_link(@two_phase_mod, %{})
    Process.sleep(10)
    pid
  end

  def do_start_stopping do
    {:ok, pid} = RuntimeAgent.start_link(@stopping_mod, %{})
    Process.sleep(30)
    pid
  end

  def do_get_phase(pid) do
    if Process.alive?(pid) do
      {:ok, RuntimeAgent.get_phase(pid)}
    else
      :dead
    end
  end

  def do_get_state(pid) do
    if Process.alive?(pid) do
      {:ok, RuntimeAgent.get_state(pid)}
    else
      :dead
    end
  end

  def do_get_events(pid) do
    if Process.alive?(pid) do
      {:ok, RuntimeAgent.get_events(pid)}
    else
      :dead
    end
  end

  def do_stop(pid) do
    if Process.alive?(pid) do
      try do
        :gen_statem.stop(pid)
        :stopped
      catch
        :exit, _ -> :already_dead
      end
    else
      :already_dead
    end
  end

  # ------------------------------------------------------------------
  # Preconditions
  # ------------------------------------------------------------------

  def precondition(_state, {:call, _, _, _}), do: true

  # ------------------------------------------------------------------
  # Postconditions
  # ------------------------------------------------------------------

  def postcondition(_state, {:call, _, :do_start_parking, []}, result) do
    is_pid(result)
  end

  def postcondition(_state, {:call, _, :do_start_two_phase, []}, result) do
    is_pid(result)
  end

  def postcondition(_state, {:call, _, :do_start_stopping, []}, result) do
    is_pid(result)
  end

  def postcondition(state, {:call, _, :do_get_phase, [pid]}, result) do
    case find_agent(state, pid) do
      {_pid, expected_phase, true} ->
        result == {:ok, expected_phase}

      {_pid, _phase, false} ->
        result == :dead

      nil ->
        true
    end
  end

  def postcondition(state, {:call, _, :do_get_state, [pid]}, result) do
    case find_agent(state, pid) do
      {_pid, _phase, true} ->
        match?({:ok, %{}}, result)

      {_pid, _phase, false} ->
        result == :dead

      nil ->
        true
    end
  end

  def postcondition(state, {:call, _, :do_get_events, [pid]}, result) do
    case find_agent(state, pid) do
      {_pid, _phase, true} ->
        match?({:ok, events} when is_list(events), result)

      {_pid, _phase, false} ->
        result == :dead

      nil ->
        true
    end
  end

  def postcondition(_state, {:call, _, :do_stop, [_pid]}, result) do
    result in [:stopped, :already_dead]
  end

  # ------------------------------------------------------------------
  # Next state
  # ------------------------------------------------------------------

  def next_state(state, result, {:call, _, :do_start_parking, []}) do
    %{state | agents: [{result, :waiting, true} | state.agents]}
  end

  def next_state(state, result, {:call, _, :do_start_two_phase, []}) do
    %{state | agents: [{result, :active, true} | state.agents]}
  end

  def next_state(state, result, {:call, _, :do_start_stopping, []}) do
    %{state | agents: [{result, :done, false} | state.agents]}
  end

  def next_state(state, _result, {:call, _, :do_get_phase, [_pid]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_get_state, [_pid]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_get_events, [_pid]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_stop, [pid]}) do
    agents =
      Enum.map(state.agents, fn
        {^pid, phase, _alive} -> {pid, phase, false}
        other -> other
      end)

    %{state | agents: agents}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp find_agent(state, pid) do
    Enum.find(state.agents, fn {p, _phase, _alive} -> p == pid end)
  end

  # ------------------------------------------------------------------
  # Property
  # ------------------------------------------------------------------

  property "agent lifecycle operations maintain consistency with model",
           [:verbose, {:numtests, 30}] do
    forall cmds <- commands(__MODULE__) do
      {history, state, result} = run_commands(__MODULE__, cmds)

      # Clean up remaining alive agents
      Enum.each(state.agents, fn {pid, _phase, alive} ->
        if alive and is_pid(pid) and Process.alive?(pid) do
          try do
            :gen_statem.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        """)
      )
    end
  end
end
