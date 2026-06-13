defmodule Skein.Runtime.Topic do
  @moduledoc """
  In-memory pub/sub topic dispatch for compiled Skein topic handlers.

  Manages subscriptions between topic names and handler functions,
  and dispatches published messages to ALL subscribers (fan-out semantics).

  Unlike queues (which are designed for single-consumer processing),
  topics broadcast every message to every subscriber.

  ## Usage

  Topic handlers declared in Skein source:

      handler topic "order.events" (msg) -> {
        let data = msg.body
        respond.json(200, data)
      }

  Are compiled and registered at startup:

      Skein.Runtime.Topic.subscribe("order.events", MyModule, :__handler_0__)

  Messages are published and dispatched to all subscribers:

      Skein.Runtime.Topic.publish("order.events", %{body: "payload"}, capabilities)
  """

  use GenServer

  alias Skein.Runtime.Trace

  @doc """
  Starts the topic dispatcher process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Subscribes a module's handler function to a named topic.
  """
  @spec subscribe(String.t(), module(), atom()) :: :ok
  def subscribe(topic_name, module, handler_fn) do
    ensure_started()
    GenServer.call(__MODULE__, {:subscribe, topic_name, {:module, module, handler_fn}})
  end

  @doc """
  Subscribes a function to a named topic (for testing).
  """
  @spec subscribe_fn(String.t(), function()) :: :ok
  def subscribe_fn(topic_name, fun) when is_function(fun, 1) do
    ensure_started()
    GenServer.call(__MODULE__, {:subscribe, topic_name, {:fn, fun}})
  end

  @doc """
  Publishes a message to a named topic. The message is dispatched
  asynchronously to ALL subscribers (fan-out).

  Returns `{:ok, message}` once the broadcast is dispatched, or
  `{:error, reason}` when the `topic.publish` capability is missing.
  Returning a Result lets `topic.publish(...)!`/`?` behave like every
  other effect rather than crashing on the un-wrapped `:ok`.
  """
  @spec publish(String.t(), term(), list()) :: {:ok, term()} | {:error, String.t()}
  def publish(topic_name, message, capabilities) do
    case check_capability("topic.publish", topic_name, capabilities) do
      :ok ->
        ensure_started()
        GenServer.cast(__MODULE__, {:publish, topic_name, message})
        {:ok, message}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns a list of all subscribed topic names.
  """
  @spec list_topics() :: [String.t()]
  def list_topics do
    ensure_started()
    GenServer.call(__MODULE__, :list_topics)
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
  def handle_call({:subscribe, topic_name, handler}, _from, state) do
    subs = Map.update(state.subscriptions, topic_name, [handler], &[handler | &1])
    {:reply, :ok, %{state | subscriptions: subs}}
  end

  def handle_call(:list_topics, _from, state) do
    {:reply, Map.keys(state.subscriptions), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_cast({:publish, topic_name, message}, state) do
    case Map.get(state.subscriptions, topic_name, []) do
      [] ->
        :ok

      handlers ->
        Enum.each(handlers, fn handler ->
          Trace.with_span(%{kind: :topic, topic: topic_name}, fn ->
            dispatch_handler(handler, message)
          end)
        end)
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp check_capability(kind, name, capabilities) do
    matching_caps = Enum.filter(capabilities, fn cap -> cap.kind == kind end)

    case matching_caps do
      [] ->
        {:error, "Capability '#{kind}' not declared. Operation on '#{name}' blocked."}

      caps ->
        match =
          Enum.any?(caps, fn cap ->
            case cap.params do
              [] -> true
              params -> name in params
            end
          end)

        if match do
          :ok
        else
          declared = caps |> Enum.flat_map(fn cap -> cap.params end) |> Enum.join(", ")

          {:error, "'#{name}' not declared in #{kind} capabilities. Declared: #{declared}"}
        end
    end
  end

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
