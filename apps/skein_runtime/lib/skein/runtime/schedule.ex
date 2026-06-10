defmodule Skein.Runtime.Schedule do
  @moduledoc """
  Cron-style schedule dispatch for compiled Skein schedule handlers.

  Manages registrations between cron expressions and handler functions.
  Registered handlers fire automatically: a periodic tick (1s by default)
  evaluates every registered cron expression against the wall clock and
  fires matching handlers through the dispatch path, at most once per
  cron minute. Handlers can also be triggered manually.

  ## Usage

  Schedule handlers declared in Skein source:

      handler schedule "*/5 * * * *" () -> {
        respond.json(200, "tick")
      }

  Are compiled and registered at startup (`Skein.Runtime.Server` does this
  for every `:schedule` entry in the module's `__handlers__/0`):

      Skein.Runtime.Schedule.register("*/5 * * * *", MyModule, :__handler_0__)

  For testing, handlers can be triggered manually (no dedup applies):

      Skein.Runtime.Schedule.trigger("*/5 * * * *")

  ## Configuration

  - `config :skein_runtime, schedule_auto_tick: false` — disable the
    periodic tick (the test suite does this; ticks are injected instead)
  - `config :skein_runtime, schedule_tick_ms: 1_000` — tick granularity

  ## Cron expressions

  Standard 5 fields (minute, hour, day-of-month, month, weekday), each
  a comma-separated list of `*`, `n`, `a-b`, `*/n`, or `a-b/n`. Weekday
  is 0-7 with both 0 and 7 meaning Sunday. When both day-of-month and
  weekday are restricted, the match is their OR (standard cron rule).
  """

  use GenServer

  alias Skein.Runtime.Trace

  @field_specs [
    {:minute, 0, 59},
    {:hour, 0, 23},
    {:day, 1, 31},
    {:month, 1, 12},
    {:weekday, 0, 7}
  ]

  @doc """
  Starts the schedule dispatcher process.

  Options:
  - `:name` — process name (default `#{inspect(__MODULE__)}`)
  - `:auto_tick` — start the periodic tick (default from app env, `true`)
  - `:tick_ms` — tick interval in ms (default from app env, 1000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a module's handler function for a cron expression.

  Returns `{:error, reason}` for an invalid cron expression.
  """
  @spec register(String.t(), module(), atom()) :: :ok | {:error, String.t()}
  def register(cron_expr, module, handler_fn) do
    ensure_started()
    GenServer.call(__MODULE__, {:register, cron_expr, {:module, module, handler_fn}})
  end

  @doc """
  Registers a function for a cron expression (for testing).

  Returns `{:error, reason}` for an invalid cron expression.
  """
  @spec register_fn(String.t(), function()) :: :ok | {:error, String.t()}
  def register_fn(cron_expr, fun) when is_function(fun, 1) do
    ensure_started()
    GenServer.call(__MODULE__, {:register, cron_expr, {:fn, fun}})
  end

  @doc """
  Manually triggers all handlers registered for the given cron expression.
  Returns `:ok` even if no handlers are registered. Manual triggering is
  not deduplicated against automatic firing.
  """
  @spec trigger(String.t()) :: :ok
  def trigger(cron_expr) do
    ensure_started()
    GenServer.call(__MODULE__, {:trigger, cron_expr})
  end

  @doc """
  Evaluates all registered cron expressions at the given time, firing
  matching handlers (with per-minute dedup) exactly as the periodic tick
  does. Used by tests to drive the clock deterministically.
  """
  @spec tick_at(DateTime.t()) :: :ok
  def tick_at(%DateTime{} = datetime) do
    ensure_started()
    GenServer.call(__MODULE__, {:tick_at, datetime})
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

  @doc """
  Compiles a cron expression into a matcher usable with `cron_match?/2`.

  Each field compiles to `:any` (for `*`) or the set of matching integer
  values. Weekday 7 normalizes to 0 (Sunday).
  """
  @spec compile_cron(String.t()) :: {:ok, map()} | {:error, String.t()}
  def compile_cron(expr) when is_binary(expr) do
    with {:ok, fields} <- parse_cron(expr) do
      @field_specs
      |> Enum.reduce_while({:ok, %{}}, fn {key, min, max}, {:ok, acc} ->
        case compile_field(Map.fetch!(fields, key), min, max) do
          {:ok, matcher} ->
            {:cont, {:ok, Map.put(acc, key, matcher)}}

          {:error, reason} ->
            {:halt, {:error, "Invalid cron field '#{key}': #{reason}"}}
        end
      end)
      |> case do
        {:ok, compiled} -> {:ok, normalize_weekday(compiled)}
        error -> error
      end
    end
  end

  @doc """
  Returns true when the compiled cron expression matches the given time.

  Standard cron rule: when both day-of-month and weekday are restricted
  (non-`*`), the date matches if either field matches.
  """
  @spec cron_match?(map(), DateTime.t()) :: boolean()
  def cron_match?(compiled, %DateTime{} = datetime) do
    weekday = rem(Date.day_of_week(DateTime.to_date(datetime)), 7)

    field_match?(compiled.minute, datetime.minute) and
      field_match?(compiled.hour, datetime.hour) and
      field_match?(compiled.month, datetime.month) and
      date_match?(compiled.day, compiled.weekday, datetime.day, weekday)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    auto_tick? =
      Keyword.get(
        opts,
        :auto_tick,
        Application.get_env(:skein_runtime, :schedule_auto_tick, true)
      )

    tick_ms =
      Keyword.get(opts, :tick_ms, Application.get_env(:skein_runtime, :schedule_tick_ms, 1_000))

    if auto_tick? do
      {:ok, _ref} = :timer.send_interval(tick_ms, :tick)
    end

    {:ok, %{registrations: %{}, compiled: %{}, last_fired: %{}}}
  end

  @impl true
  def handle_call({:register, cron_expr, handler}, _from, state) do
    case compile_cron(cron_expr) do
      {:ok, compiled} ->
        regs = Map.update(state.registrations, cron_expr, [handler], &[handler | &1])
        compiled_map = Map.put(state.compiled, cron_expr, compiled)
        {:reply, :ok, %{state | registrations: regs, compiled: compiled_map}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:trigger, cron_expr}, _from, state) do
    fire_handlers(cron_expr, Map.get(state.registrations, cron_expr, []))
    {:reply, :ok, state}
  end

  def handle_call({:tick_at, datetime}, _from, state) do
    {:reply, :ok, do_tick(datetime, state)}
  end

  def handle_call(:list_schedules, _from, state) do
    {:reply, Map.keys(state.registrations), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{registrations: %{}, compiled: %{}, last_fired: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, do_tick(DateTime.utc_now(), state)}
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  # Fires every registration whose cron expression matches the given
  # time and hasn't already fired in this cron minute.
  defp do_tick(datetime, state) do
    minute_key = {datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute}

    Enum.reduce(state.registrations, state, fn {cron_expr, handlers}, acc ->
      compiled = Map.fetch!(acc.compiled, cron_expr)
      already_fired? = Map.get(acc.last_fired, cron_expr) == minute_key

      if not already_fired? and cron_match?(compiled, datetime) do
        fire_handlers(cron_expr, handlers)
        %{acc | last_fired: Map.put(acc.last_fired, cron_expr, minute_key)}
      else
        acc
      end
    end)
  end

  defp fire_handlers(cron_expr, handlers) do
    Enum.each(handlers, fn handler ->
      Trace.with_span(%{kind: :schedule, cron: cron_expr}, fn ->
        dispatch_handler(handler)
      end)
    end)
  end

  defp dispatch_handler({:module, module, handler_fn}) do
    apply(module, handler_fn, [%{}])
  end

  defp dispatch_handler({:fn, fun}) do
    fun.(%{})
  end

  # ------------------------------------------------------------------
  # Cron field compilation and matching
  # ------------------------------------------------------------------

  # A field compiles to :any (wildcard with no step) or a MapSet of the
  # matching integers. Comma-separated terms union together.
  defp compile_field("*", _min, _max), do: {:ok, :any}

  defp compile_field(field, min, max) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn term, {:ok, acc} ->
      case compile_term(term, min, max) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp compile_term(term, min, max) do
    {base, step} =
      case String.split(term, "/") do
        [base] -> {base, 1}
        [base, step] -> {base, step}
        _ -> {term, :invalid}
      end

    with {:ok, step} <- parse_step(step),
         {:ok, range_min, range_max} <- parse_base(base, min, max) do
      {:ok, MapSet.new(range_min..range_max//1, & &1) |> step_filter(range_min, step)}
    end
  end

  defp parse_step(1), do: {:ok, 1}

  defp parse_step(step) when is_binary(step) do
    case Integer.parse(step) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> {:error, "invalid step '#{step}'"}
    end
  end

  defp parse_step(:invalid), do: {:error, "too many '/' separators"}

  defp parse_base("*", min, max), do: {:ok, min, max}

  defp parse_base(base, min, max) do
    case String.split(base, "-") do
      [single] ->
        with {:ok, n} <- parse_field_int(single, min, max) do
          {:ok, n, n}
        end

      [from, to] ->
        with {:ok, from_n} <- parse_field_int(from, min, max),
             {:ok, to_n} <- parse_field_int(to, min, max) do
          if from_n <= to_n do
            {:ok, from_n, to_n}
          else
            {:error, "range '#{base}' is reversed"}
          end
        end

      _ ->
        {:error, "invalid range '#{base}'"}
    end
  end

  defp parse_field_int(value, min, max) do
    case Integer.parse(value) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      {n, ""} -> {:error, "value #{n} out of range #{min}-#{max}"}
      _ -> {:error, "'#{value}' is not a number"}
    end
  end

  defp step_filter(values, range_min, step) do
    MapSet.filter(values, fn n -> rem(n - range_min, step) == 0 end)
  end

  # Weekday 7 is Sunday, same as 0.
  defp normalize_weekday(%{weekday: :any} = compiled), do: compiled

  defp normalize_weekday(%{weekday: weekdays} = compiled) do
    normalized =
      if MapSet.member?(weekdays, 7) do
        weekdays |> MapSet.delete(7) |> MapSet.put(0)
      else
        weekdays
      end

    %{compiled | weekday: normalized}
  end

  defp field_match?(:any, _value), do: true
  defp field_match?(values, value), do: MapSet.member?(values, value)

  # Standard cron: when both day-of-month and weekday are restricted, the
  # date matches if EITHER matches; otherwise the restricted one decides.
  defp date_match?(:any, weekday_matcher, _day, weekday),
    do: field_match?(weekday_matcher, weekday)

  defp date_match?(day_matcher, :any, day, _weekday), do: field_match?(day_matcher, day)

  defp date_match?(day_matcher, weekday_matcher, day, weekday) do
    field_match?(day_matcher, day) or field_match?(weekday_matcher, weekday)
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
