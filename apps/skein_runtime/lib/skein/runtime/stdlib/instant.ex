defmodule Skein.Runtime.Stdlib.Instant do
  @moduledoc """
  Standard library functions for the Skein `Instant` type.

  Instants are represented as ISO 8601 UTC datetime strings internally,
  backed by Elixir's DateTime.
  """

  @spec now() :: binary()
  def now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @spec parse(binary()) :: {:ok, binary()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, DateTime.to_iso8601(dt)}
      {:error, reason} -> {:error, "invalid instant: #{inspect(reason)}"}
    end
  end

  @spec to_string(binary()) :: binary()
  def to_string(instant) when is_binary(instant), do: instant

  @spec add(binary(), binary()) :: binary()
  def add(instant, duration_seconds) when is_binary(instant) do
    seconds = parse_duration_seconds(duration_seconds)
    {:ok, dt, _} = DateTime.from_iso8601(instant)
    DateTime.add(dt, seconds, :second) |> DateTime.to_iso8601()
  end

  @spec subtract(binary(), binary()) :: binary()
  def subtract(instant, duration_seconds) when is_binary(instant) do
    seconds = parse_duration_seconds(duration_seconds)
    {:ok, dt, _} = DateTime.from_iso8601(instant)
    DateTime.add(dt, -seconds, :second) |> DateTime.to_iso8601()
  end

  @spec diff(binary(), binary()) :: integer()
  def diff(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.diff(dt_a, dt_b, :second)
  end

  @spec is_before(binary(), binary()) :: boolean()
  def is_before(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.compare(dt_a, dt_b) == :lt
  end

  @spec is_after(binary(), binary()) :: boolean()
  def is_after(a, b) when is_binary(a) and is_binary(b) do
    {:ok, dt_a, _} = DateTime.from_iso8601(a)
    {:ok, dt_b, _} = DateTime.from_iso8601(b)
    DateTime.compare(dt_a, dt_b) == :gt
  end

  defp parse_duration_seconds(val) when is_integer(val), do: val
  defp parse_duration_seconds(val) when is_binary(val), do: String.to_integer(val)
end
