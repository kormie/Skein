defmodule Skein.Runtime.Process do
  @moduledoc """
  Supervised process spawning for compiled Skein process.spawn effect calls.

  Spawns short-lived tasks under a DynamicSupervisor, providing crash isolation
  and automatic cleanup. Each spawned process is monitored and traced.
  """

  use DynamicSupervisor

  alias Skein.Runtime.Capability
  alias Skein.Runtime.SpawnContext
  alias Skein.Runtime.Replay
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
  def spawn(fun, capabilities) when is_function(fun, 0) do
    case check_capability(capabilities) do
      :ok ->
        ensure_started()
        # Capture the scenario capability context here, in the spawning process,
        # so the spawned body resolves effects identically to inline work (#282).
        bound = SpawnContext.bind(fun)

        replayable_spawn(%{kind: :process, method: :spawn}, fn -> start_supervised_task(bound) end)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Spawns a supervised task: either a compiled `process.spawn("name")` call
  or a function with arguments.

  For the pool/task form, the pool is the scoped capability label (spec
  §3.2) threaded in by the compiler from the module's
  `capability process.spawn(pool)` declaration (`nil` when the declaration
  is parameterless). Calls outside the declared pool are blocked. The task
  is spawned as a supervised no-op carrying the name and pool in its trace
  span; user-defined task bodies are a planned extension.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec spawn(String.t() | nil | function(), String.t() | list(), list()) ::
          {:ok, pid()} | {:error, term()}
  def spawn(pool, task_name, capabilities)
      when (is_binary(pool) or is_nil(pool)) and is_binary(task_name) and is_list(capabilities) do
    case Capability.check_scoped("process.spawn", pool, capabilities) do
      :ok ->
        ensure_started()

        replayable_spawn(%{kind: :process, method: :spawn, task: task_name, pool: pool}, fn ->
          start_supervised_task(fn -> :ok end)
        end)

      {:error, _reason} = error ->
        error
    end
  end

  def spawn(fun, args, capabilities) when is_function(fun) and is_list(args) do
    case check_capability(capabilities) do
      :ok ->
        ensure_started()
        bound = SpawnContext.bind(fn -> apply(fun, args) end)

        replayable_spawn(%{kind: :process, method: :spawn}, fn -> start_supervised_task(bound) end)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Spawns a supervised task that executes a task body — the runtime entry
  point for compiled `process.spawn("name", &some_fn)` calls.

  The pool is the scoped capability label (spec §3.2); see `spawn/3`. The
  zero-arity function runs in the supervised task; crashes are isolated by
  the supervisor and never take down the caller.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec spawn(String.t() | nil, String.t(), function(), list()) ::
          {:ok, pid()} | {:error, term()}
  def spawn(pool, task_name, fun, capabilities)
      when (is_binary(pool) or is_nil(pool)) and is_binary(task_name) and is_function(fun, 0) and
             is_list(capabilities) do
    case Capability.check_scoped("process.spawn", pool, capabilities) do
      :ok ->
        ensure_started()
        # Capture the scenario capability context here, in the spawning process,
        # so the spawned body resolves effects identically to inline work (#282).
        bound = SpawnContext.bind(fun)

        replayable_spawn(%{kind: :process, method: :spawn, task: task_name, pool: pool}, fn ->
          start_supervised_task(bound)
        end)

      {:error, _reason} = error ->
        error
    end
  end

  defp replayable_spawn(metadata, start_fun) do
    Trace.with_recorded_span(metadata, fn ->
      case Replay.next_response(:process, Map.take(metadata, [:method, :task, :pool])) do
        {:ok, _recorded} ->
          # Golden replay must not spawn background work. Return the caller pid as
          # an inert pid-shaped handle while marking the trace as replayed.
          {{:ok, self()}, %{replayed: true, result: :ok}}

        :no_replay ->
          result = start_fun.()
          {result, %{spawn_id: inspect(make_ref()), result: result_tag(result)}}

        :exhausted ->
          {{:error, "Replay trace exhausted: no recorded process spawn remains"}, %{replayed: true}}

        {:mismatch, message} ->
          {{:error, message}, %{replayed: true}}
      end
    end)
  end

  defp result_tag({:ok, _pid}), do: :ok
  defp result_tag({:error, reason}), do: inspect(reason)

  @doc false
  # Runs `fun` in a temporary supervised Task — the crash-isolation primitive
  # behind `process.spawn` work bodies, also used by Timer task bodies.
  @spec start_supervised_task((-> any())) :: {:ok, pid()} | {:error, String.t()}
  def start_supervised_task(fun) when is_function(fun, 0) do
    ensure_started()

    case DynamicSupervisor.start_child(__MODULE__, %{
           id: make_ref(),
           start: {Task, :start_link, [fun]},
           restart: :temporary
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, inspect(reason)}
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
