defmodule Skein.Runtime.Trace do
  @moduledoc """
  Trace capture and storage for Skein effect calls.

  Records trace spans for every effect call with timing, metadata, and outcome.
  Uses an ETS table for in-process trace storage.

  Spans are stored as maps with at minimum:
  - `:kind` — the effect type (e.g., `:http`)
  - `:method` — the specific operation (e.g., `:get`, `:post`)
  - `:url` — the target URL
  - `:status` — HTTP status code (if applicable)
  - `:duration_us` — wall-clock duration in microseconds
  - `:outcome` — `:ok` or `:error`
  - `:timestamp` — monotonic timestamp when the span was recorded
  """

  @table :skein_trace_spans

  @doc """
  Ensures the trace ETS table exists. Called automatically by the application.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Records a trace span. Adds a monotonic timestamp automatically.
  """
  @spec record_span(map()) :: :ok
  def record_span(span) when is_map(span) do
    init()
    timestamp = System.monotonic_time(:microsecond)
    # Use a unique key based on timestamp + unique_integer for ordering
    key = {timestamp, System.unique_integer([:monotonic, :positive])}
    enriched = Map.merge(span, %{timestamp: timestamp, _key: key})
    :ets.insert(@table, {key, enriched})
    :ok
  end

  @doc """
  Returns the most recent `count` spans, ordered newest first.
  """
  @spec recent_spans(pos_integer()) :: [map()]
  def recent_spans(count) when is_integer(count) and count > 0 do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, span} -> span end)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(count)
  end

  @doc """
  Removes all recorded spans.
  """
  @spec clear() :: :ok
  def clear do
    init()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Adds a key-value annotation to the trace log.

  Annotations are recorded as spans with `kind: :annotation`, making them
  visible alongside regular effect spans in the trace output.

  This is the runtime backing for `trace.annotate(key, value)` in Skein source.
  """
  @spec annotate(String.t(), String.t()) :: :ok
  def annotate(key, value) do
    record_span(%{kind: :annotation, key: key, value: value})
  end

  @doc """
  Adds a key-value annotation to the trace log.

  Three-argument form used by compiled Skein code. The capabilities
  argument is accepted for consistency with other effect calls but is
  not used — trace annotations do not require any capability.
  """
  @spec annotate(String.t(), String.t(), list()) :: :ok
  def annotate(key, value, _capabilities) do
    annotate(key, value)
  end

  @doc """
  Executes a function and records a trace span with timing.

  The `metadata` map should contain at least `:kind`, `:method`, and `:url`.
  The function's return value determines the outcome:
  - `{:ok, _}` or any non-error value → `:ok`
  - `{:error, _}` → `:error`
  - exception → `:error` with error message

  Returns the function's return value (re-raises exceptions).
  """
  @spec with_span(map(), (-> any())) :: any()
  def with_span(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      duration = System.monotonic_time(:microsecond) - start

      {outcome, status} =
        case result do
          {:error, _} -> {:error, nil}
          {:ok, %{status: s}} -> {:ok, s}
          _ -> {:ok, nil}
        end

      span =
        metadata
        |> Map.merge(%{duration_us: duration, outcome: outcome})
        |> then(fn s -> if status, do: Map.put(s, :status, status), else: s end)

      record_span(span)
      result
    rescue
      exception ->
        duration = System.monotonic_time(:microsecond) - start

        span =
          Map.merge(metadata, %{
            duration_us: duration,
            outcome: :error,
            error: Exception.message(exception)
          })

        record_span(span)
        reraise exception, __STACKTRACE__
    end
  end
end
