defmodule Skein.Runtime.Stdlib.Duration do
  @moduledoc """
  Standard library functions for the Skein `Duration` type.

  Durations represent time spans and are stored as integer seconds internally.
  Used with `Instant` for time arithmetic and with `timer.*` for scheduling.

  ## Examples (Skein)

      let d = Duration.minutes(30)
      Duration.to_seconds(d)        -- 1800
      Duration.to_string(d)         -- "30m"
  """

  @doc "Creates a duration from a number of seconds."
  @spec seconds(integer()) :: integer()
  def seconds(n) when is_integer(n), do: n

  @doc "Creates a duration from a number of minutes."
  @spec minutes(integer()) :: integer()
  def minutes(n) when is_integer(n), do: n * 60

  @doc "Creates a duration from a number of hours."
  @spec hours(integer()) :: integer()
  def hours(n) when is_integer(n), do: n * 3600

  @doc "Creates a duration from a number of days."
  @spec days(integer()) :: integer()
  def days(n) when is_integer(n), do: n * 86400

  @doc "Returns the total number of seconds in the duration."
  @spec to_seconds(integer()) :: integer()
  def to_seconds(duration) when is_integer(duration), do: duration

  @doc ~S"""
  Returns a human-readable string like `"30m"`, `"2h"`, or `"45s"`.
  """
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
