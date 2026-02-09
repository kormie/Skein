defmodule Skein.Runtime.Stdlib.Float do
  @moduledoc """
  Standard library functions for the Skein `Float` type.

  Maps Skein's `Float.function()` calls to Elixir/Erlang implementations.
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

  @spec to_string(float()) :: binary()
  def to_string(f) when is_float(f) do
    Float.to_string(f)
  end

  @spec round(float(), non_neg_integer()) :: float()
  def round(f, decimals) when is_float(f) and is_integer(decimals) do
    Float.round(f, decimals)
  end

  @spec ceil(float()) :: integer()
  def ceil(f) when is_float(f) do
    Float.ceil(f) |> Kernel.trunc()
  end

  @spec floor(float()) :: integer()
  def floor(f) when is_float(f) do
    Float.floor(f) |> Kernel.trunc()
  end
end
