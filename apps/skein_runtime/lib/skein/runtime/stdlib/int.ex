defmodule Skein.Runtime.Stdlib.Int do
  @moduledoc """
  Standard library functions for the Skein `Int` type.

  In Skein source code these are called as `Int.parse("42")`,
  `Int.abs(-5)`, etc.

  ## Examples (Skein)

      Int.parse("42")          -- Ok(42)
      Int.abs(-5)              -- 5
      Int.clamp(15, 0, 10)     -- 10
  """

  @doc """
  Parses a string into an integer.

  Returns `{:ok, integer}` on success or `{:error, message}` if the string
  is not a valid integer.
  """
  @spec parse(binary()) :: {:ok, integer()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "invalid integer: #{s}"}
    end
  end

  @doc "Converts an integer to its string representation."
  @spec to_string(integer()) :: binary()
  def to_string(n) when is_integer(n) do
    Integer.to_string(n)
  end

  @doc "Returns the absolute value of `n`."
  @spec abs(integer()) :: non_neg_integer()
  def abs(n) when is_integer(n) do
    Kernel.abs(n)
  end

  @doc "Returns the smaller of `a` and `b`."
  @spec min(integer(), integer()) :: integer()
  def min(a, b) when is_integer(a) and is_integer(b) do
    Kernel.min(a, b)
  end

  @doc "Returns the larger of `a` and `b`."
  @spec max(integer(), integer()) :: integer()
  def max(a, b) when is_integer(a) and is_integer(b) do
    Kernel.max(a, b)
  end

  @doc "Constrains `n` to the range `[low, high]`."
  @spec clamp(integer(), integer(), integer()) :: integer()
  def clamp(n, low, high) when is_integer(n) and is_integer(low) and is_integer(high) do
    n |> Kernel.max(low) |> Kernel.min(high)
  end
end
