defmodule Skein.Runtime.EventStore.SqliteBackend do
  @moduledoc """
  SQLite persistent backend for the EventStore.

  Events are serialized to JSON and stored in a `skein_events` table.
  ETS remains the fast read path; this module handles persistence
  so events survive BEAM restarts.
  """

  alias Skein.Runtime.Repo
  alias Skein.Runtime.EventStore

  @table_name "skein_events"

  @doc """
  Creates the skein_events table if it doesn't exist.
  """
  @spec migrate() :: :ok
  def migrate do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TABLE IF NOT EXISTS #{@table_name} (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      data TEXT NOT NULL
    )
    """)

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE INDEX IF NOT EXISTS idx_skein_events_kind ON #{@table_name} (kind)
    """)

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE INDEX IF NOT EXISTS idx_skein_events_timestamp ON #{@table_name} (timestamp)
    """)

    :ok
  end

  @doc """
  Appends an event to both ETS (via EventStore) and SQLite.
  """
  @spec append(map()) :: :ok
  def append(event) when is_map(event) do
    # First append to ETS to get enriched event with id/timestamp
    EventStore.init()

    timestamp = System.monotonic_time(:microsecond)
    key = {timestamp, System.unique_integer([:monotonic, :positive])}
    id = generate_id()

    enriched =
      event
      |> Map.put(:id, id)
      |> Map.put(:timestamp, timestamp)
      |> Map.put(:_key, key)

    # Write to ETS
    :ets.insert(:skein_events, {key, enriched})

    # Write to SQLite
    kind = to_string(Map.get(event, :kind, "unknown"))
    # Store the full event as JSON (minus internal _key)
    data = enriched |> Map.delete(:_key) |> encode_event()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO #{@table_name} (id, kind, timestamp, data) VALUES (?1, ?2, ?3, ?4)
      """,
      [id, kind, timestamp, data]
    )

    :ok
  end

  @doc """
  Loads all events from SQLite, oldest first.
  """
  @spec load_all() :: [map()]
  def load_all do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Repo, """
      SELECT data FROM #{@table_name} ORDER BY timestamp ASC
      """)

    Enum.map(rows, fn [data] -> decode_event(data) end)
  end

  @doc """
  Queries events from SQLite by filters.
  """
  @spec query(keyword()) :: [map()]
  def query(filters) when is_list(filters) do
    events = load_all()

    Enum.filter(events, fn event ->
      Enum.all?(filters, fn {k, v} ->
        Map.get(event, k) == v
      end)
    end)
  end

  @doc """
  Loads all SQLite events into the ETS cache.
  Call on startup to restore state.
  """
  @spec load_into_ets() :: :ok
  def load_into_ets do
    EventStore.init()

    events = load_all()

    for event <- events do
      key = {event.timestamp, System.unique_integer([:monotonic, :positive])}
      enriched = Map.put(event, :_key, key)
      :ets.insert(:skein_events, {key, enriched})
    end

    :ok
  end

  @doc """
  Removes all events from SQLite.
  """
  @spec clear() :: :ok
  def clear do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{@table_name}")
    :ok
  end

  # Encode event map to JSON, converting atom keys/values for storage
  defp encode_event(event) do
    event
    |> stringify_atoms()
    |> Jason.encode!()
  end

  # Decode JSON back to event map with atom keys where appropriate
  defp decode_event(json) do
    json
    |> Jason.decode!()
    |> atomize_event()
  end

  defp stringify_atoms(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_map(v), do: stringify_atoms(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  # Convert known keys back to atoms
  @atom_keys ~w(id kind timestamp method operation namespace key value event data order outcome duration_us wall_time)

  defp atomize_event(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      atom_key = if k in @atom_keys, do: String.to_atom(k), else: k
      value = atomize_value(atom_key, v)
      {atom_key, value}
    end)
    |> Map.new()
  end

  # Known atom-valued fields
  @atom_value_keys [:kind, :method, :operation, :outcome]

  defp atomize_value(key, v) when key in @atom_value_keys and is_binary(v) do
    String.to_atom(v)
  end

  defp atomize_value(_key, v), do: v

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
