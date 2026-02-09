defmodule Skein.Runtime.Stdlib.Int do
  @moduledoc """
  Standard library functions for the Skein `Int` type.

  Maps Skein's `Int.function()` calls to Elixir/Erlang implementations.
  """

  @spec parse(binary()) :: {:ok, integer()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "invalid integer: #{s}"}
    end
  end

  @spec to_string(integer()) :: binary()
  def to_string(n) when is_integer(n) do
    Integer.to_string(n)
  end

  @spec abs(integer()) :: non_neg_integer()
  def abs(n) when is_integer(n) do
    Kernel.abs(n)
  end

  @spec min(integer(), integer()) :: integer()
  def min(a, b) when is_integer(a) and is_integer(b) do
    Kernel.min(a, b)
  end

  @spec max(integer(), integer()) :: integer()
  def max(a, b) when is_integer(a) and is_integer(b) do
    Kernel.max(a, b)
  end

  @spec clamp(integer(), integer(), integer()) :: integer()
  def clamp(n, low, high) when is_integer(n) and is_integer(low) and is_integer(high) do
    n |> Kernel.max(low) |> Kernel.min(high)
  end
end
