defmodule Skein.Runtime.Agent do
  @moduledoc """
  Runtime support for Skein agent state machines.

  Provides a thin wrapper around `:gen_statem` that manages the agent lifecycle:
  - Starting agents with initial parameters
  - Phase transitions with validation
  - Stop and emit operations
  - State access within handlers

  Uses internal events to trigger phase handler execution. When a transition
  occurs, the gen_statem moves to the new state and queues an `:execute_phase`
  internal event, which then runs the phase handler.

  ## Generated Module Interface

  Each compiled Skein agent generates a module with:
  - `start_link/1` — Start the agent with initial params
  - `__phases__/0` — Return phase metadata (variants and transitions)
  - `__start_handler__/2` — The `on start(...)` handler
  - `__phase_handler__/3` — Phase-specific handlers dispatched by phase name
  """

  @doc """
  Starts an agent process. Called by the generated `start_link/1`.

  `module` is the compiled agent module atom.
  `args` is the map of initial parameters passed to `on start(...)`.
  """
  @spec start(module(), map()) :: {:ok, pid()} | {:error, term()}
  def start(module, args) do
    :gen_statem.start(__MODULE__, {module, args}, [])
  end

  @spec start_link(module(), map()) :: {:ok, pid()} | {:error, term()}
  def start_link(module, args) do
    :gen_statem.start_link(__MODULE__, {module, args}, [])
  end

  @doc """
  Returns the current phase of the agent.
  """
  @spec get_phase(pid()) :: atom()
  def get_phase(pid) do
    :gen_statem.call(pid, :get_phase)
  end

  @doc """
  Returns the current state data of the agent.
  """
  @spec get_state(pid()) :: map()
  def get_state(pid) do
    :gen_statem.call(pid, :get_state)
  end

  @doc """
  Returns the list of events emitted by the agent.
  """
  @spec get_events(pid()) :: [map()]
  def get_events(pid) do
    :gen_statem.call(pid, :get_events)
  end

  @doc """
  Returns whether the agent is currently suspended.
  """
  @spec is_suspended?(pid()) :: boolean()
  def is_suspended?(pid) do
    :gen_statem.call(pid, :is_suspended)
  end

  @doc """
  Returns the suspension reason if the agent is suspended, nil otherwise.
  """
  @spec get_suspend_reason(pid()) :: String.t() | nil
  def get_suspend_reason(pid) do
    :gen_statem.call(pid, :get_suspend_reason)
  end

  @doc """
  Resumes a suspended agent, transitioning it to the given phase.

  The agent must be in the `:suspended` state. The `next_phase` atom
  determines which phase handler will be executed next.
  """
  @spec resume(pid(), atom()) :: :ok | {:error, :not_suspended}
  def resume(pid, next_phase) do
    :gen_statem.call(pid, {:resume, next_phase})
  end

  # ------------------------------------------------------------------
  # gen_statem callbacks
  # ------------------------------------------------------------------

  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({module, args}) do
    data = %{
      module: module,
      state: %{},
      events: [],
      args: args,
      suspend_reason: nil
    }

    # Call the start handler which should return a transition action
    result = module.__start_handler__(args, data.state)
    handle_init_result(result, data)
  end

  @impl true
  # Internal event to execute the phase handler after a transition
  def handle_event(:internal, :execute_phase, phase, data) do
    module = data.module
    result = module.__phase_handler__(phase, data.state, data.events)
    handle_phase_result(result, data)
  end

  # Query operations via call
  def handle_event({:call, from}, :get_phase, phase, data) do
    {:keep_state, data, [{:reply, from, phase}]}
  end

  def handle_event({:call, from}, :get_state, _phase, data) do
    {:keep_state, data, [{:reply, from, data.state}]}
  end

  def handle_event({:call, from}, :get_events, _phase, data) do
    {:keep_state, data, [{:reply, from, data.events}]}
  end

  def handle_event({:call, from}, :is_suspended, phase, data) do
    {:keep_state, data, [{:reply, from, phase == :suspended}]}
  end

  def handle_event({:call, from}, :get_suspend_reason, _phase, data) do
    {:keep_state, data, [{:reply, from, data.suspend_reason}]}
  end

  # Resume: transition from :suspended to a new phase
  def handle_event({:call, from}, {:resume, next_phase}, :suspended, data) do
    new_data = %{data | suspend_reason: nil}

    {:next_state, next_phase, new_data,
     [{:reply, from, :ok}, {:next_event, :internal, :execute_phase}]}
  end

  # Resume when not suspended: error
  def handle_event({:call, from}, {:resume, _next_phase}, _phase, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_suspended}}]}
  end

  # Fallback — ignore unknown events
  def handle_event(_event_type, _event, _phase, data) do
    {:keep_state, data}
  end

  # ------------------------------------------------------------------
  # Init result processing
  # ------------------------------------------------------------------

  defp handle_init_result(result, data) do
    case result do
      {:transition, next_phase, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        # Transition to the phase and queue the phase handler execution
        {:ok, next_phase, new_data, [{:next_event, :internal, :execute_phase}]}

      {:suspend, reason, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events,
            suspend_reason: reason
        }

        {:ok, :suspended, new_data}

      {:stop, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        {:stop, :normal, new_data}

      {:keep, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        {:ok, :__idle__, new_data}

      other ->
        {:stop, {:unexpected_handler_result, :start, other}}
    end
  end

  # ------------------------------------------------------------------
  # Phase handler result processing
  # ------------------------------------------------------------------

  defp handle_phase_result(result, data) do
    case result do
      {:transition, next_phase, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        {:next_state, next_phase, new_data, [{:next_event, :internal, :execute_phase}]}

      {:suspend, reason, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events,
            suspend_reason: reason
        }

        {:next_state, :suspended, new_data}

      {:stop, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        {:stop, :normal, new_data}

      {:keep, new_state, new_events} ->
        new_data = %{
          data
          | state: merge_state(data.state, new_state),
            events: data.events ++ new_events
        }

        {:keep_state, new_data}

      _other ->
        # Non-control-flow return (e.g., bare expression) — keep state
        {:keep_state, data}
    end
  end

  defp merge_state(old, new) when is_map(new), do: Map.merge(old, new)
  defp merge_state(old, _), do: old
end
