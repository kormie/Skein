defmodule Skein.Runtime.Timer do
  @moduledoc """
  Timer management for compiled Skein timer effect calls.

  Provides one-shot (`after`) and recurring (`interval`) timers with
  cancellation support. Timers are tracked in an ETS table and
  associated with trace spans.
  """

  use GenServer

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

  Returns `{:ok, timer_ref}` where timer_ref is a unique string identifier.
  The capabilities argument is passed by compiled Skein code for consistency.

  Note: Named `unquote(:after)` because `after` is a reserved word in Elixir,
  but the BEAM function atom must be `:after` to match codegen output.
  """
  # Use unquote(:after) to define a function named :after (reserved word in Elixir)
  def unquote(:after)(delay_ms, callback, capabilities)

  def unquote(:after)(delay_ms, callback, capabilities)
      when is_integer(delay_ms) and delay_ms >= 0 and is_function(callback, 0) do
    case check_capability(capabilities) do
      :ok ->
        ensure_started()

        Trace.with_span(%{kind: :timer, method: :after, delay_ms: delay_ms}, fn ->
          timer_ref = generate_ref()

          erlang_ref =
            :erlang.send_after(delay_ms, __MODULE__, {:fire, timer_ref, :once, callback})

          :ets.insert(@table, {timer_ref, erlang_ref, :once, callback, delay_ms})
          {:ok, timer_ref}
        end)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Schedules a recurring timer that fires the callback every `interval_ms` milliseconds.

  Returns `{:ok, timer_ref}` where timer_ref is a unique string identifier.
  The capabilities argument is passed by compiled Skein code for consistency.
  """
  @spec interval(integer(), function(), list()) :: {:ok, String.t()} | {:error, String.t()}
  def interval(interval_ms, callback, capabilities)
      when is_integer(interval_ms) and interval_ms > 0 and is_function(callback, 0) do
    case check_capability(capabilities) do
      :ok ->
        ensure_started()

        Trace.with_span(%{kind: :timer, method: :interval, interval_ms: interval_ms}, fn ->
          timer_ref = generate_ref()

          erlang_ref =
            :erlang.send_after(
              interval_ms,
              __MODULE__,
              {:fire, timer_ref, :recurring, callback}
            )

          :ets.insert(@table, {timer_ref, erlang_ref, :recurring, callback, interval_ms})
          {:ok, timer_ref}
        end)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Cancels a previously scheduled timer.

  Returns `:ok` regardless of whether the timer was found.
  The capabilities argument is passed by compiled Skein code for consistency.
  """
  @spec cancel(String.t(), list()) :: :ok | {:error, String.t()}
  def cancel(timer_ref, capabilities) when is_binary(timer_ref) do
    case check_capability(capabilities) do
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

    try do
      if Process.whereis(__MODULE__) do
        GenServer.stop(__MODULE__, :normal)
      end
    catch
      :exit, _ -> :ok
    end

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

  defp check_capability(capabilities) do
    if Enum.any?(capabilities, fn cap -> cap.kind == "timer" end) do
      :ok
    else
      {:error, "Capability 'timer' not declared. Timer operations blocked."}
    end
  end

  defp safe_execute(callback) do
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
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
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
