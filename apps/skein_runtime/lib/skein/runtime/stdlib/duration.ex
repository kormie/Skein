defmodule Skein.Runtime.Stdlib.Duration do
  @moduledoc """
  Standard library functions for the Skein `Duration` type.

  Durations are represented as integer seconds internally.
  """

  @spec seconds(integer()) :: integer()
  def seconds(n) when is_integer(n), do: n

  @spec minutes(integer()) :: integer()
  def minutes(n) when is_integer(n), do: n * 60

  @spec hours(integer()) :: integer()
  def hours(n) when is_integer(n), do: n * 3600

  @spec days(integer()) :: integer()
  def days(n) when is_integer(n), do: n * 86400

  @spec to_seconds(integer()) :: integer()
  def to_seconds(duration) when is_integer(duration), do: duration

  @spec to_string(integer()) :: binary()
  def to_string(duration) when is_integer(duration) do
    cond do
      duration >= 86400 and rem(duration, 86400) == 0 ->
        "#{div(duration, 86400)}d"

      duration >= 3600 and rem(duration, 3600) == 0 ->
        "#{div(duration, 3600)}h"

      duration >= 60 and rem(duration, 60) == 0 ->
        "#{div(duration, 60)}m"

      true ->
        "#{duration}s"
    end
  end
end
