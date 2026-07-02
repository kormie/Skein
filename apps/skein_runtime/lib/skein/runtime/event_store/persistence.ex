defmodule Skein.Runtime.EventStore.Persistence do
  @moduledoc """
  Opt-in SQLite persistence for the EventStore (issue #299 / roadmap C6).

  This GenServer owns the persistence lifecycle. By default the EventStore
  is in-memory only; calling `enable/1` with a database path makes every
  ordinary `Skein.Runtime.EventStore.append/1` also write the event to
  SQLite (via `Skein.Runtime.EventStore.SqliteBackend`). `skein run`
  enables persistence by default at `<project>/.skein/events.db`
  (`--no-persist` opts out).

  ## Lifecycle

  - `enable/1` (idempotent) starts `Skein.Runtime.Repo` on the given
    database, runs the backend migration, reloads previously persisted
    events into the ETS log (deduplicated by event id, so a restarted
    service sees its history), and flips the persistence flag.
  - `disable/0` clears the flag; the Repo is left running.
  - Writes are asynchronous: `EventStore.append/1` casts the enriched
    event here (`record/1`), and this process writes it to SQLite.
    `flush/0` blocks until the write queue has drained — call it before
    shutdown (or in tests) to force durability.

  ## Persisted-and-reloaded event shape

  Events round-trip through JSON, so a reloaded event is NOT bit-identical
  to what was appended:

  - keys in the backend's known metadata set (`id`, `kind`, `timestamp`,
    `event`, `stream`, `data`, `method`, `operation`, `namespace`, `key`,
    `value`, `order`, `outcome`, `duration_us`, `wall_time`) come back as
    atom keys; all other keys come back as string keys
  - `kind`/`method`/`operation`/`outcome` values are re-atomized; all
    other atom values come back as strings (`nil` and booleans are
    preserved as JSON null/booleans)
  - nested map data keeps its JSON shape (string keys throughout)
  - `id` and `timestamp` are the original append-time values (note that
    `timestamp` is a monotonic time from the previous VM run, so it is
    only meaningful for ordering within that run's events)

  These shapes are FROZEN as of the Wave F gate (#332): the frozen
  vectors in `event_store_freeze_test.exs` pin the reloaded map per
  persisted class. Shapes only gain fields within a major
  (`docs/STABILITY.md`).
  """

  use GenServer

  require Logger

  alias Skein.Runtime.EventStore.SqliteBackend
  alias Skein.Runtime.Repo

  @flag :skein_event_persistence

  # ------------------------------------------------------------------
  # Client API
  # ------------------------------------------------------------------

  @doc """
  Starts the persistence server (normally supervised by the runtime
  application; `enable/1` starts it on demand as a fallback).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enables persistence against the SQLite database at `db_path`. Idempotent.

  Starts `Skein.Runtime.Repo` on `db_path` (restarting it if it is already
  running against a different database), runs the backend migration,
  reloads previously persisted events into the ETS log (deduplicated by
  event id), and flips the persistence flag so subsequent
  `EventStore.append/1` calls are persisted.
  """
  @spec enable(String.t()) :: :ok | {:error, term()}
  def enable(db_path) when is_binary(db_path) do
    with :ok <- ensure_started() do
      GenServer.call(__MODULE__, {:enable, db_path}, 30_000)
    end
  end

  @doc """
  Disables persistence: ordinary appends stop being written to SQLite.
  The Repo is left running. Already-persisted events are untouched.
  """
  @spec disable() :: :ok
  def disable do
    :persistent_term.put(@flag, false)
    :ok
  end

  @doc """
  Returns true when persistence is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :persistent_term.get(@flag, false)
  end

  @doc """
  Asynchronously persists an enriched event (as produced by
  `EventStore.append/1`, with `:id`/`:timestamp` set and the internal
  `:_key` already dropped). Called by `EventStore.append/1` when the
  persistence flag is set; a no-op cast when the server is not running.
  """
  @spec record(map()) :: :ok
  def record(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:record, event})
  end

  @doc """
  Blocks until all queued asynchronous writes have been flushed to SQLite.
  Returns `:ok` immediately when the server is not running.
  """
  @spec flush() :: :ok
  def flush do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :flush, 30_000)
    end
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{db_path: nil}}
  end

  @impl true
  def handle_call({:enable, db_path}, _from, state) do
    if enabled?() and state.db_path == db_path do
      {:reply, :ok, state}
    else
      case do_enable(db_path, state) do
        {:ok, new_state} -> {:reply, :ok, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:flush, _from, state) do
    # Casts are processed in order, so by the time this call is served
    # every previously queued write has hit SQLite.
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    if enabled?() do
      try do
        SqliteBackend.persist(event)
      rescue
        error ->
          Logger.warning("EventStore persistence write failed: #{Exception.message(error)}")
      end
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp do_enable(db_path, state) do
    File.mkdir_p!(Path.dirname(db_path))

    with :ok <- ensure_repo(db_path, state) do
      :ok = SqliteBackend.migrate()
      :ok = SqliteBackend.load_into_ets()
      :persistent_term.put(@flag, true)
      {:ok, %{state | db_path: db_path}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp ensure_repo(db_path, state) do
    case Repo.start_link(database: db_path, pool_size: 1) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        if state.db_path == db_path do
          # Already running against the requested database.
          :ok
        else
          # Running against a different (or unknown) database — restart it
          # on the requested path.
          restart_repo(db_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restart_repo(db_path) do
    try do
      GenServer.stop(Repo, :normal, 5000)
    catch
      :exit, _ -> :ok
    end

    case Repo.start_link(database: db_path, pool_size: 1) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end
end
