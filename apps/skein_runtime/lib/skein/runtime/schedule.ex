defmodule Skein.Runtime.Schedule do
  @moduledoc """
  Cron-style schedule dispatch for compiled Skein schedule handlers.

  Manages registrations between cron expressions and handler functions,
  and triggers handlers on schedule or on demand.

  ## Usage

  Schedule handlers declared in Skein source:

      handler schedule "*/5 * * * *" () -> {
        respond.json(200, "tick")
      }

  Are compiled and registered at startup:

      Skein.Runtime.Schedule.register("*/5 * * * *", MyModule, :__handler_0__)

  For testing, handlers can be triggered manually:

      Skein.Runtime.Schedule.trigger("*/5 * * * *")
  """

  use GenServer

  alias Skein.Runtime.Trace

  @doc """
  Starts the schedule dispatcher process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Registers a module's handler function for a cron expression.
  """
  @spec register(String.t(), module(), atom()) :: :ok
  def register(cron_expr, module, handler_fn) do
    ensure_started()
    GenServer.call(__MODULE__, {:register, cron_expr, {:module, module, handler_fn}})
  end

  @doc """
  Registers a function for a cron expression (for testing).
  """
  @spec register_fn(String.t(), function()) :: :ok
  def register_fn(cron_expr, fun) when is_function(fun, 1) do
    ensure_started()
    GenServer.call(__MODULE__, {:register, cron_expr, {:fn, fun}})
  end

  @doc """
  Manually triggers all handlers registered for the given cron expression.
  Returns `:ok` even if no handlers are registered.
  """
  @spec trigger(String.t()) :: :ok
  def trigger(cron_expr) do
    ensure_started()
    GenServer.call(__MODULE__, {:trigger, cron_expr})
  end

  @doc """
  Returns a list of all registered cron expressions.
  """
  @spec list_schedules() :: [String.t()]
  def list_schedules do
    ensure_started()
    GenServer.call(__MODULE__, :list_schedules)
  end

  @doc """
  Resets all registrations. Used in tests.
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

  @doc """
  Parses a standard 5-field cron expression into a structured map.

  Fields: minute, hour, day (of month), month, weekday

  ## Examples

      iex> Skein.Runtime.Schedule.parse_cron("*/5 * * * *")
      {:ok, %{minute: "*/5", hour: "*", day: "*", month: "*", weekday: "*"}}

      iex> Skein.Runtime.Schedule.parse_cron("bad")
      {:error, "Invalid cron expression: expected 5 space-separated fields"}
  """
  @spec parse_cron(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_cron(expr) when is_binary(expr) do
    fields = String.split(expr, " ", trim: true)

    case fields do
      [minute, hour, day, month, weekday] ->
        {:ok,
         %{
           minute: minute,
           hour: hour,
           day: day,
           month: month,
           weekday: weekday
         }}

      _ ->
        {:error, "Invalid cron expression: expected 5 space-separated fields"}
    end
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{registrations: %{}}}
  end

  @impl true
  def handle_call({:register, cron_expr, handler}, _from, state) do
    regs = Map.update(state.registrations, cron_expr, [handler], &[handler | &1])
    {:reply, :ok, %{state | registrations: regs}}
  end

  def handle_call({:trigger, cron_expr}, _from, state) do
    handlers = Map.get(state.registrations, cron_expr, [])

    Enum.each(handlers, fn handler ->
      Trace.with_span(%{kind: :schedule, cron: cron_expr}, fn ->
        dispatch_handler(handler)
      end)
    end)

    {:reply, :ok, state}
  end

  def handle_call(:list_schedules, _from, state) do
    {:reply, Map.keys(state.registrations), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{registrations: %{}}}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp dispatch_handler({:module, module, handler_fn}) do
    apply(module, handler_fn, [%{}])
  end

  defp dispatch_handler({:fn, fun}) do
    fun.(%{})
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
