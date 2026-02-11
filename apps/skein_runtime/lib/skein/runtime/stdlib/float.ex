defmodule Skein.Runtime.Stdlib.Float do
  @moduledoc """
  Standard library functions for the Skein `Float` type.

  In Skein source code these are called as `Float.parse("3.14")`,
  `Float.round(3.456, 2)`, etc.

  ## Examples (Skein)

      Float.parse("3.14")     -- Ok(3.14)
      Float.round(3.456, 2)   -- 3.46
      Float.ceil(2.1)          -- 3.0
      Float.floor(2.9)         -- 2.0
  """

  @doc """
  Parses a string into a float.

  Also accepts integer strings (e.g. `"42"` becomes `42.0`).
  Returns `{:ok, float}` on success or `{:error, message}` on failure.
  """
  @spec parse(binary()) :: {:ok, float()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} ->
        {:ok, f}

      # Also accept integer strings as valid floats
      :error ->
        case Integer.parse(s) do
          {n, ""} -> {:ok, n * 1.0}
          _ -> {:error, "invalid float: #{s}"}
        end

      _ ->
        {:error, "invalid float: #{s}"}
    end
  end

  @doc "Converts a float to its string representation."
  @spec to_string(float()) :: binary()
  def to_string(f) when is_float(f) do
    Float.to_string(f)
  end

  @doc "Rounds `f` to the given number of `decimals` places."
  @spec round(float(), non_neg_integer()) :: float()
  def round(f, decimals) when is_float(f) and is_integer(decimals) do
    Float.round(f, decimals)
  end

  @doc "Rounds `f` up to the nearest integer."
  @spec ceil(float()) :: integer()
  def ceil(f) when is_float(f) do
    Float.ceil(f) |> Kernel.trunc()
  end

  @doc "Rounds `f` down to the nearest integer."
  @spec floor(float()) :: integer()
  def floor(f) when is_float(f) do
    Float.floor(f) |> Kernel.trunc()
  end
end
