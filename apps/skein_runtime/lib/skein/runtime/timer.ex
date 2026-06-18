defmodule Skein.Runtime.Timer do
  @moduledoc """
  Timer management for compiled Skein timer effect calls.

  Provides one-shot (`after`) and recurring (`interval`) timers with
  cancellation support. Timers are tracked in an ETS table and
  associated with trace spans.
  """

  use GenServer

  alias Skein.Runtime.Capability
  alias Skein.Runtime.SpawnContext
  alias Skein.Runtime.Trace

  @table :skein_runtime_timers

  @doc """
  Starts the timer manager process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Schedules a one-shot timer that fires the callback after `delay_ms` milliseconds.

  The group is the scoped capability label (spec §3.2) threaded in by the
  compiler from the module's `capability timer(group)` declaration (`nil`
  when the declaration is parameterless). Calls outside the declared group
  are blocked. The callback may be a zero-arity function or a string task
  name from compiled `timer.after(delay, "task")` calls — string tasks fire
  as named no-ops recorded in the trace (see `after/5` for task bodies).

  Returns `{:ok, timer_ref}` where timer_ref is a unique string identifier.

  Note: Named `unquote(:after)` because `after` is a reserved word in Elixir,
  but the BEAM function atom must be `:after` to match codegen output.
  """
  # Use unquote(:after) to define a function named :after (reserved word in Elixir)
  def unquote(:after)(group, delay_ms, callback, capabilities)

  def unquote(:after)(group, delay_ms, callback, capabilities)
      when (is_binary(group) or is_nil(group)) and is_integer(delay_ms) and delay_ms >= 0 and
             (is_function(callback, 0) or is_binary(callback) or
                (is_tuple(callback) and elem(callback, 0) == :named_work)) do
    case Capability.check_scoped("timer", group, capabilities) do
      :ok ->
        ensure_started()

        Trace.with_span(
          %{kind: :timer, method: :after, delay_ms: delay_ms, group: group},
          fn ->
            timer_ref = generate_ref()
            fire = normalize_callback(callback)

            erlang_ref =
              :erlang.send_after(delay_ms, __MODULE__, {:fire, timer_ref, :once, fire})

            :ets.insert(@table, {timer_ref, erlang_ref, :once, fire, delay_ms})
            {:ok, timer_ref}
          end
        )

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Schedules a one-shot timer whose named task runs `work` (a zero-arity
  function) inside a supervised task when it fires (spec §6.11) — compiled
  `timer.after(delay, "task", &fn)` calls land here.
  """
  def unquote(:after)(group, delay_ms, task, work, capabilities)
      when (is_binary(group) or is_nil(group)) and is_integer(delay_ms) and delay_ms >= 0 and
             is_binary(task) and is_function(work, 0) do
    # Capture the scenario capability context here, at schedule time, so the body
    # resolves effects under the scheduling scenario's envelope/policy when it
    # later fires inside the timer manager — not in that manager's bare context (#282).
    apply(__MODULE__, :after, [
      group,
      delay_ms,
      {:named_work, task, SpawnContext.bind(work)},
      capabilities
    ])
  end

  @doc """
  Schedules a recurring timer that fires the callback every `interval_ms`
  milliseconds.

  The group is the scoped capability label (spec §3.2); see `after/4`.
  The callback may be a zero-arity function or a string task name.

  Returns `{:ok, timer_ref}` where timer_ref is a unique string identifier.
  """
  @spec interval(String.t() | nil, integer(), function() | String.t(), list()) ::
          {:ok, String.t()} | {:error, String.t()}
  def interval(group, interval_ms, callback, capabilities)
      when (is_binary(group) or is_nil(group)) and is_integer(interval_ms) and interval_ms > 0 and
             (is_function(callback, 0) or is_binary(callback) or
                (is_tuple(callback) and elem(callback, 0) == :named_work)) do
    case Capability.check_scoped("timer", group, capabilities) do
      :ok ->
        ensure_started()

        Trace.with_span(
          %{kind: :timer, method: :interval, interval_ms: interval_ms, group: group},
          fn ->
            timer_ref = generate_ref()
            fire = normalize_callback(callback)

            erlang_ref =
              :erlang.send_after(
                interval_ms,
                __MODULE__,
                {:fire, timer_ref, :recurring, fire}
              )

            :ets.insert(@table, {timer_ref, erlang_ref, :recurring, fire, interval_ms})
            {:ok, timer_ref}
          end
        )

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Schedules a recurring timer whose named task runs `work` (a zero-arity
  function) inside a supervised task on every fire (spec §6.11) — compiled
  `timer.interval(every, "task", &fn)` calls land here.
  """
  @spec interval(String.t() | nil, integer(), String.t(), (-> any()), list()) ::
          {:ok, String.t()} | {:error, String.t()}
  def interval(group, interval_ms, task, work, capabilities)
      when (is_binary(group) or is_nil(group)) and is_integer(interval_ms) and interval_ms > 0 and
             is_binary(task) and is_function(work, 0) do
    # Capture the scenario capability context at schedule time so every fire runs
    # the body under the scheduling scenario's envelope/policy (#282).
    interval(group, interval_ms, {:named_work, task, SpawnContext.bind(work)}, capabilities)
  end

  @doc """
  Cancels a previously scheduled timer.

  The group is the scoped capability label (spec §3.2); see `after/4`.

  Returns `:ok` regardless of whether the timer was found.
  """
  @spec cancel(String.t() | nil, String.t(), list()) :: :ok | {:error, String.t()}
  def cancel(group, timer_ref, capabilities)
      when (is_binary(group) or is_nil(group)) and is_binary(timer_ref) do
    case Capability.check_scoped("timer", group, capabilities) do
      :ok ->
        cancel_impl(timer_ref)

      {:error, _reason} = error ->
        error
    end
  end

  defp cancel_impl(timer_ref) do
    ensure_started()

    Trace.with_span(%{kind: :timer, method: :cancel, timer_ref: timer_ref}, fn ->
      case :ets.lookup(@table, timer_ref) do
        [{^timer_ref, erlang_ref, _type, _callback, _ms}] ->
          :erlang.cancel_timer(erlang_ref)
          :ets.delete(@table, timer_ref)

        [] ->
          :ok
      end

      :ok
    end)
  end

  @doc """
  Returns a list of all active timer refs.
  """
  @spec list_timers() :: [String.t()]
  def list_timers do
    ensure_started()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {ref, _erlang_ref, _type, _callback, _ms} -> ref end)
  end

  @doc """
  Resets all timers. Used in tests.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      if :ets.whereis(@table) != :undefined do
        @table
        |> :ets.tab2list()
        |> Enum.each(fn {_ref, erlang_ref, _type, _callback, _ms} ->
          :erlang.cancel_timer(erlang_ref)
        end)

        :ets.delete_all_objects(@table)
      end
    rescue
      ArgumentError -> :ok
    end

    # Note: do NOT stop the GenServer here. The timer table holds all state,
    # and the process is supervised — repeated stops would exhaust the
    # supervisor's restart intensity and take the whole application down.
    :ok
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    init_table()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:fire, timer_ref, :once, callback}, state) do
    :ets.delete(@table, timer_ref)
    safe_execute(callback)
    {:noreply, state}
  end

  def handle_info({:fire, timer_ref, :recurring, callback}, state) do
    case :ets.lookup(@table, timer_ref) do
      [{^timer_ref, _old_ref, :recurring, ^callback, interval_ms}] ->
        # Reschedule
        new_erlang_ref =
          :erlang.send_after(interval_ms, __MODULE__, {:fire, timer_ref, :recurring, callback})

        :ets.insert(@table, {timer_ref, new_erlang_ref, :recurring, callback, interval_ms})
        safe_execute(callback)

      [] ->
        # Timer was cancelled, don't fire
        :ok
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  # Compiled `timer.after(delay, "task")` calls carry a string task name;
  # the task fires as a named no-op recorded in the trace. With a `work`
  # fn (`timer.after(delay, "task", &fn)`) the body runs in a supervised
  # task on fire. Bare function callbacks execute as-is.
  defp normalize_callback(task) when is_binary(task), do: {:task, task}
  defp normalize_callback({:named_work, _task, _work} = callback), do: callback
  defp normalize_callback(callback) when is_function(callback, 0), do: callback

  defp safe_execute({:task, task_name}) do
    Trace.with_span(%{kind: :timer, event: :fire, task: task_name}, fn -> :ok end)
  end

  # Work bodies run in a temporary supervised task (the process.spawn
  # primitive), so a crashing body never takes down the timer manager.
  defp safe_execute({:named_work, task_name, work}) do
    Trace.with_span(%{kind: :timer, event: :fire, task: task_name}, fn ->
      Skein.Runtime.Process.start_supervised_task(work)
    end)
  end

  defp safe_execute(callback) when is_function(callback, 0) do
    Trace.with_span(%{kind: :timer, event: :fire}, fn ->
      try do
        callback.()
      rescue
        e -> {:error, Exception.message(e)}
      end
    end)
  end

  defp generate_ref do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp init_table do
    Skein.Runtime.EtsTables.ensure_table(
      @table,
      [:named_table, :set, :public, read_concurrency: true]
    )
  end

  # Fallback for environments where the application supervisor isn't
  # running (e.g. tests with --no-start). Tolerates concurrent start races.
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
