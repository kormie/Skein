defmodule Skein.Runtime.Stdlib.Instant do
  @moduledoc """
  Standard library functions for the Skein `Instant` type.

  Instants represent a point in time, stored as ISO 8601 UTC datetime strings
  internally and backed by Elixir's `DateTime`.

  ## Examples (Skein)

      let now = Instant.now()
      let later = Instant.add(now, Duration.hours(2))
      Instant.is_before(now, later)  -- true
      Instant.diff(later, now)       -- Duration (2 hours)
  """

  @doc "Returns the current UTC timestamp as an ISO 8601 string."
  @spec now() :: binary()
  def now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @doc """
  Parses an ISO 8601 datetime string.

  Returns `{:ok, instant}` on success or `{:error, message}` on failure.
  """
  @spec parse(binary()) :: {:ok, binary()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, DateTime.to_iso8601(dt)}
      {:error, reason} -> {:error, "invalid instant: #{inspect(reason)}"}
    end
  end

  @doc "Returns the ISO 8601 string representation of an instant."
  @spec to_string(binary()) :: binary()
  def to_string(instant) when is_binary(instant), do: instant

  @doc "Adds a duration (in seconds) to an instant, returning a new instant."
  @spec add(binary(), binary()) :: binary()
  def add(instant, duration_seconds) when is_binary(instant) do
    seconds = parse_duration_seconds(duration_seconds)
    {:ok, dt, _} = DateTime.from_iso8601(instant)
    DateTime.add(dt, seconds, :second) |> DateTime.to_iso8601()
  end

  @doc "Subtracts a duration (in seconds) from an instant, returning a new instant."
  @spec subtract(binary(), binary()) :: binary()
  def subtract(instant, duration_seconds) when is_binary(instant) do
    seconds = parse_duration_seconds(duration_seconds)
    {:ok, dt, _} = DateTime.from_iso8601(instant)
    DateTime.add(dt, -seconds, :second) |> DateTime.to_iso8601()
  end

  @doc "Returns the difference between two instants as a Duration (integer seconds)."
  @spec diff(binary(), binary()) :: integer()
  def diff(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.diff(dt_a, dt_b, :second)
  end

  @doc "Returns `true` if instant `a` is chronologically before instant `b`."
  @spec is_before(binary(), binary()) :: boolean()
  def is_before(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.compare(dt_a, dt_b) == :lt
  end

  @doc "Returns `true` if instant `a` is chronologically after instant `b`."
  @spec is_after(binary(), binary()) :: boolean()
  def is_after(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.compare(dt_a, dt_b) == :gt
  end

  defp parse_duration_seconds(val) when is_integer(val), do: val
  defp parse_duration_seconds(val) when is_binary(val), do: String.to_integer(val)
end
