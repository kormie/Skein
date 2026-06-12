defmodule Skein.Runtime.Queue do
  @moduledoc """
  In-memory message queue dispatch for compiled Skein queue handlers.

  Manages subscriptions between queue names and handler functions,
  and dispatches published messages to the appropriate handlers.

  ## Usage

  Queue handlers declared in Skein source:

      handler queue "order-events" (msg) -> {
        let data = msg.body
        respond.json(200, data)
      }

  Are compiled and registered at startup:

      Skein.Runtime.Queue.subscribe("order-events", MyModule, :__handler_0__)

  Messages are published and dispatched asynchronously:

      Skein.Runtime.Queue.publish("order-events", %{body: "payload"})
  """

  use GenServer

  alias Skein.Runtime.Trace

  @doc """
  Starts the queue dispatcher process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Subscribes a module's handler function to a named queue.
  """
  @spec subscribe(String.t(), module(), atom()) :: :ok
  def subscribe(queue_name, module, handler_fn) do
    ensure_started()
    GenServer.call(__MODULE__, {:subscribe, queue_name, {:module, module, handler_fn}})
  end

  @doc """
  Subscribes a function to a named queue (for testing).
  """
  @spec subscribe_fn(String.t(), function()) :: :ok
  def subscribe_fn(queue_name, fun) when is_function(fun, 1) do
    ensure_started()
    GenServer.call(__MODULE__, {:subscribe, queue_name, {:fn, fun}})
  end

  @doc """
  Publishes a message to a named queue. The message is dispatched
  asynchronously to all subscribers.
  """
  @spec publish(String.t(), map()) :: :ok
  def publish(queue_name, message) do
    ensure_started()
    GenServer.cast(__MODULE__, {:publish, queue_name, message})
  end

  @doc """
  Publishes a message to a named queue, checking the `queue.publish`
  capability first. This is the entry point for compiled Skein code
  (`queue.publish(name, data)`), mirroring `Skein.Runtime.Topic.publish/3`.
  """
  @spec publish(String.t(), term(), list()) :: :ok | {:error, String.t()}
  def publish(queue_name, message, capabilities) do
    case Skein.Runtime.Capability.check_scoped("queue.publish", queue_name, capabilities) do
      :ok ->
        publish(queue_name, message)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns a list of all subscribed queue names.
  """
  @spec list_queues() :: [String.t()]
  def list_queues do
    ensure_started()
    GenServer.call(__MODULE__, :list_queues)
  end

  @doc """
  Resets all subscriptions. Used in tests.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      if Process.whereis(__MODULE__) do
        GenServer.call(__MODULE__, :reset)
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
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_call({:subscribe, queue_name, handler}, _from, state) do
    subs = Map.update(state.subscriptions, queue_name, [handler], &[handler | &1])
    {:reply, :ok, %{state | subscriptions: subs}}
  end

  def handle_call(:list_queues, _from, state) do
    {:reply, Map.keys(state.subscriptions), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_cast({:publish, queue_name, message}, state) do
    case Map.get(state.subscriptions, queue_name, []) do
      [] ->
        :ok

      handlers ->
        Enum.each(handlers, fn handler ->
          Trace.with_span(%{kind: :queue, queue: queue_name}, fn ->
            dispatch_handler(handler, message)
          end)
        end)
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp dispatch_handler({:module, module, handler_fn}, message) do
    try do
      apply(module, handler_fn, [message])
    catch
      {:idempotent_skip} -> :ok
    end
  end

  defp dispatch_handler({:fn, fun}, message) do
    try do
      fun.(message)
    catch
      {:idempotent_skip} -> :ok
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
