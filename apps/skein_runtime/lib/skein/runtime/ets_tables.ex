defmodule Skein.Runtime.EtsTables do
  @moduledoc """
  Single long-lived owner for the runtime's named ETS tables.

  ETS tables are destroyed when their owning process exits. The runtime's
  tables were previously created lazily by whichever process first touched
  them — when that process was transient (an HTTP request, a queue dispatch,
  an agent instance, a test process), the table silently died with it,
  wiping state for every other user of the table (#118).

  All named runtime tables are therefore created through this GenServer.
  It is supervised by the runtime application (first child, so tables can
  be requested from sibling `init/1` callbacks) and does nothing but own
  tables, so it never crashes and the tables live for the lifetime of the
  application. The `ensure_started/0` fallback covers `--no-start`
  environments and deliberately starts the owner *unlinked* — a linked
  owner would die with its transient starter, recreating the original bug.
  """

  use GenServer

  @doc """
  Starts the table owner. Called by the application supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures `name` exists as a named ETS table with `opts`, created by (and
  therefore owned by) the table owner process. Idempotent and race-safe;
  tables must be `:public` for callers to read and write them.
  """
  @spec ensure_table(atom(), list()) :: :ok
  def ensure_table(name, opts) when is_atom(name) and is_list(opts) do
    if :ets.whereis(name) == :undefined do
      request_table(name, opts, 3)
    end

    :ok
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure_table, name, opts}, _from, state) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, opts)
    end

    {:reply, :ok, state}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  # The owner can disappear between the whereis check and the call (e.g. an
  # application shutdown race in tests) — retry rather than crash the caller.
  defp request_table(name, opts, retries) do
    ensure_started()
    GenServer.call(__MODULE__, {:ensure_table, name, opts})
  catch
    :exit, _ when retries > 0 -> request_table(name, opts, retries - 1)
  end

  # Fallback for environments where the application supervisor isn't running
  # (e.g. tests with --no-start). Tolerates concurrent start races. Must NOT
  # link to the caller: the whole point is outliving transient callers.
  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
