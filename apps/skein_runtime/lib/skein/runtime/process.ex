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
  @spec spawn(function() | String.t(), list()) :: {:ok, pid()} | {:error, term()}
  def spawn(task_name, capabilities) when is_binary(task_name) do
    # Compiled `process.spawn("name")` calls pass a task name. The task is
    # spawned as a supervised no-op carrying the name in its trace span;
    # user-defined task bodies are a planned extension.
    case check_capability(capabilities) do
      :ok ->
        ensure_started()

        Trace.with_span(%{kind: :process, method: :spawn, task: task_name}, fn ->
          case DynamicSupervisor.start_child(__MODULE__, %{
                 id: make_ref(),
                 start: {Task, :start_link, [fn -> :ok end]},
                 restart: :temporary
               }) do
            {:ok, pid} -> {:ok, pid}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end)

      {:error, _reason} = error ->
        error
    end
  end

  def spawn(fun, capabilities) when is_function(fun, 0) do
    case check_capability(capabilities) do
      :ok ->
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

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Spawns a supervised task that executes the given function with arguments.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  The capabilities argument is passed by compiled Skein code for consistency.
  """
  @spec spawn(function(), list(), list()) :: {:ok, pid()} | {:error, term()}
  def spawn(fun, args, capabilities) when is_function(fun) and is_list(args) do
    case check_capability(capabilities) do
      :ok ->
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

      {:error, _reason} = error ->
        error
    end
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

  defp check_capability(capabilities) do
    if Enum.any?(capabilities, fn cap -> cap.kind == "process.spawn" end) do
      :ok
    else
      {:error, "Capability 'process.spawn' not declared. Process spawning blocked."}
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
