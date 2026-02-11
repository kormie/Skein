defmodule Skein.Runtime.Process do
  @moduledoc """
  Supervised process spawning for compiled Skein process.spawn effect calls.

  Spawns short-lived tasks under a DynamicSupervisor, providing crash isolation
  and automatic cleanup. Each spawned process is monitored and traced.
  """

  use DynamicSupervisor

  alias Skein.Runtime.Trace

  @doc """
  Starts the process supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawns a supervised task that executes the given function.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  The capabilities argument is passed by compiled Skein code for consistency.
  """
  @spec spawn(function(), list()) :: {:ok, pid()} | {:error, term()}
  def spawn(fun, _capabilities) when is_function(fun, 0) do
    ensure_started()

    Trace.with_span(%{kind: :process, method: :spawn}, fn ->
      case DynamicSupervisor.start_child(__MODULE__, %{
             id: make_ref(),
             start: {Task, :start_link, [fun]},
             restart: :temporary
           }) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  @doc """
  Spawns a supervised task that executes the given function with arguments.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  The capabilities argument is passed by compiled Skein code for consistency.
  """
  @spec spawn(function(), list(), list()) :: {:ok, pid()} | {:error, term()}
  def spawn(fun, args, _capabilities) when is_function(fun) and is_list(args) do
    ensure_started()

    Trace.with_span(%{kind: :process, method: :spawn}, fn ->
      case DynamicSupervisor.start_child(__MODULE__, %{
             id: make_ref(),
             start: {Task, :start_link, [fn -> apply(fun, args) end]},
             restart: :temporary
           }) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  @doc """
  Returns a list of pids for all running supervised children.
  """
  @spec list_children() :: [pid()]
  def list_children do
    ensure_started()

    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Resets the supervisor by terminating all children. Used in tests.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      if Process.whereis(__MODULE__) do
        __MODULE__
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, pid, _, _} ->
          if is_pid(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)
        end)
      end
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp ensure_started do
    unless Process.whereis(__MODULE__) do
      start_link()
    end
  end
end
