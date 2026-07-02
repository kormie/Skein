defmodule Skein.Runtime.EventStore do
  @moduledoc """
  Unified append-only event log for the Skein runtime.

  Every runtime event — effect spans, trace annotations, user-defined events,
  and memory state changes — flows through a single ordered log. This provides
  a unified "what happened" record that subsumes the previously separate
  trace and memory audit concerns.

  ## Event Kinds

  - `:effect` — an effect call (HTTP, memory access, LLM, etc.) with timing
  - `:annotation` — a `trace.annotate(key, value)` marker
  - `:user_event` — a `event.log(name, data)` user-defined event
  - `:state_change` — a memory mutation (put/delete) recording the data change

  ## Storage

  Backed by a single ETS ordered set (`:skein_events`). Events are keyed by
  `{monotonic_timestamp, unique_integer}` for stable chronological ordering.

  The log is size-bounded: once it exceeds the configured maximum, the oldest
  events are evicted on append. Configure the bound with:

      config :skein_runtime, :event_store_max_events, 100_000

  **The log is in-memory only.** Events older than the bound are gone, and
  nothing survives a VM restart. The SQLite backend module
  (`Skein.Runtime.EventStore.SqliteBackend`) exists but is NOT wired into
  the ordinary append path — the runtime neither starts nor writes to it
  today. Durable persistence is tracked by issue #299 (roadmap C6).

  Every event gets automatic metadata:
  - `id` — unique hex identifier
  - `timestamp` — monotonic microsecond timestamp
  - `_key` — internal ETS ordering key

  ## Design

  `Trace` and `Memory` delegate to this store for their unique concerns:

  - `Trace` provides the timing/instrumentation API (`with_span`, `annotate`)
  - `Memory` provides scoped KV state with capability checking and ETS caching

  User-defined events (`event.log` in Skein source) are handled directly by
  this module via `log/4` — there is no separate EventLog module. One way to
  do a thing: all queries go through `EventStore.query/1`.
  """

  alias Skein.Runtime.Capability

  @table :skein_events
  @default_max_events 100_000

  @doc """
  Ensures the event store ETS table exists.
  """
  @spec init() :: :ok
  def init do
    Skein.Runtime.EtsTables.ensure_table(
      @table,
      [:named_table, :ordered_set, :public, read_concurrency: true]
    )
  end

  @doc """
  Logs a structured user event. This is the runtime entry point for the
  `event.log(name, data)` effect call in Skein source.

  The stream is the scoped capability label (spec §3.2) threaded in by the
  compiler from the module's `capability event.log(stream)` declaration
  (`nil` when the declaration is parameterless). Calls outside the declared
  stream are blocked; the stream is recorded on the stored event.

  Returns `:ok`.
  """
  @spec log(String.t() | nil, String.t(), term(), list()) :: :ok | {:error, String.t()}
  def log(stream, event_name, data, capabilities)
      when (is_binary(stream) or is_nil(stream)) and is_binary(event_name) do
    case Capability.check_scoped("event.log", stream, capabilities) do
      :ok ->
        append(%{
          kind: :user_event,
          event: event_name,
          stream: stream,
          data: data,
          wall_time: System.system_time(:microsecond)
        })

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Appends an event to the log.

  The event map must contain at least a `:kind` field. Automatic metadata
  (`id`, `timestamp`, `_key`) is added before storage.

  Returns `:ok`.
  """
  @spec append(map()) :: :ok
  def append(event) when is_map(event) do
    init()

    timestamp = System.monotonic_time(:microsecond)
    key = {timestamp, System.unique_integer([:monotonic, :positive])}

    enriched =
      event
      |> Map.put(:id, generate_id())
      |> Map.put(:timestamp, timestamp)
      |> Map.put(:_key, key)

    :ets.insert(@table, {key, enriched})
    evict_overflow()
    :ok
  end

  @doc """
  Returns the most recent `count` events, newest first.
  """
  @spec recent(pos_integer()) :: [map()]
  def recent(count) when is_integer(count) and count > 0 do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(count)
  end

  @doc """
  Returns all events, newest first.
  """
  @spec all() :: [map()]
  def all do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  @doc """
  Queries events by filter criteria. Returns matching events newest first.

  Supported filters:
  - `kind:` — filter by event kind (atom)
  - Any other key — exact match against event fields

  ## Examples

      EventStore.query(kind: :effect)
      EventStore.query(kind: :user_event, event: "login")
      EventStore.query(kind: :state_change, namespace: "sessions")
  """
  @spec query(keyword()) :: [map()]
  def query(filters) when is_list(filters) do
    all()
    |> Enum.filter(fn event ->
      Enum.all?(filters, fn {k, v} ->
        Map.get(event, k) == v
      end)
    end)
  end

  @doc """
  Returns the total number of events, or the count matching filters.

  ## Examples

      EventStore.count()                          # total
      EventStore.count(kind: :effect)             # effects only
      EventStore.count(kind: :state_change)       # state changes only
  """
  @spec count() :: non_neg_integer()
  def count do
    init()
    :ets.info(@table, :size)
  end

  @spec count(keyword()) :: non_neg_integer()
  def count(filters) when is_list(filters) do
    query(filters) |> length()
  end

  @doc """
  Returns events with timestamps >= the given monotonic timestamp, newest first.
  """
  @spec since(integer()) :: [map()]
  def since(timestamp) when is_integer(timestamp) do
    all()
    |> Enum.filter(&(&1.timestamp >= timestamp))
  end

  @doc """
  Returns all events in chronological order (oldest first).

  This is the format used for golden test snapshots and event export.
  Internal metadata (`_key`) is stripped for clean serialization.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, event} -> Map.delete(event, :_key) end)
    |> Enum.sort_by(& &1.timestamp, :asc)
  end

  @doc """
  Removes all events from the store.
  """
  @spec clear() :: :ok
  def clear do
    init()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  # Drops the oldest events once the log exceeds the configured bound, so
  # long-running services don't leak memory through unbounded event growth.
  defp evict_overflow do
    max = Application.get_env(:skein_runtime, :event_store_max_events, @default_max_events)
    size = :ets.info(@table, :size)

    if is_integer(size) and size > max do
      evict_oldest(size - max)
    end

    :ok
  end

  defp evict_oldest(0), do: :ok

  defp evict_oldest(n) do
    case :ets.first(@table) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(@table, key)
        evict_oldest(n - 1)
    end
  end
end
