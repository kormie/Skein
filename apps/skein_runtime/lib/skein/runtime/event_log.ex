defmodule Skein.Runtime.EventLog do
  @moduledoc """
  Structured event logging for compiled Skein event.log effect calls.

  Records structured events with timestamps into an ETS-backed log.
  Each event has a name, data payload, and automatic metadata (timestamp, id).
  Events are also recorded as trace spans for observability.
  """

  alias Skein.Runtime.Trace

  @table :skein_event_log

  @doc """
  Logs a structured event with the given name and data.

  Returns `:ok`. The capabilities argument is passed by compiled Skein code
  for consistency.
  """
  @spec log(String.t(), term(), list()) :: :ok
  def log(event_name, data, _capabilities)
      when is_binary(event_name) do
    init()

    Trace.with_span(%{kind: :event_log, event: event_name}, fn ->
      event = %{
        id: generate_id(),
        event: event_name,
        data: data,
        timestamp: System.system_time(:microsecond)
      }

      key = {event.timestamp, System.unique_integer([:monotonic, :positive])}
      :ets.insert(@table, {key, event})
      :ok
    end)
  end

  @doc """
  Returns all logged events, most recent first.
  """
  @spec all() :: [map()]
  def all do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {key, _event} -> key end, :desc)
    |> Enum.map(fn {_key, event} -> event end)
  end

  @doc """
  Returns all logged events with the given event name, most recent first.
  """
  @spec query(String.t()) :: [map()]
  def query(event_name) when is_binary(event_name) do
    init()

    all()
    |> Enum.filter(fn event -> event.event == event_name end)
  end

  @doc """
  Returns the count of logged events.
  """
  @spec count() :: non_neg_integer()
  def count do
    init()
    :ets.info(@table, :size)
  end

  @doc """
  Resets all logged events. Used in tests.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      if :ets.whereis(@table) != :undefined do
        :ets.delete_all_objects(@table)
      end
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp init do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
