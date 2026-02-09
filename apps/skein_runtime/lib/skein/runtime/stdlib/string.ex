defmodule Skein.Runtime.Stdlib.String do
  @moduledoc """
  Standard library functions for the Skein `String` type.

  Maps Skein's `String.function()` calls to Elixir/Erlang implementations.
  """

  @spec length(binary()) :: non_neg_integer()
  def length(s) when is_binary(s) do
    String.length(s)
  end

  @spec slice(binary(), integer(), non_neg_integer()) :: binary()
  def slice(s, start, len) when is_binary(s) and is_integer(start) and is_integer(len) do
    String.slice(s, start, len)
  end

  @spec contains(binary(), binary()) :: boolean()
  def contains(s, sub) when is_binary(s) and is_binary(sub) do
    String.contains?(s, sub)
  end

  @spec split(binary(), binary()) :: [binary()]
  def split(s, delimiter) when is_binary(s) and is_binary(delimiter) do
    String.split(s, delimiter)
  end

  @spec trim(binary()) :: binary()
  def trim(s) when is_binary(s) do
    String.trim(s)
  end

  @spec upcase(binary()) :: binary()
  def upcase(s) when is_binary(s) do
    String.upcase(s)
  end

  @spec downcase(binary()) :: binary()
  def downcase(s) when is_binary(s) do
    String.downcase(s)
  end

  @spec starts_with(binary(), binary()) :: boolean()
  def starts_with(s, prefix) when is_binary(s) and is_binary(prefix) do
    String.starts_with?(s, prefix)
  end

  @spec ends_with(binary(), binary()) :: boolean()
  def ends_with(s, suffix) when is_binary(s) and is_binary(suffix) do
    String.ends_with?(s, suffix)
  end

  @spec replace(binary(), binary(), binary()) :: binary()
  def replace(s, pattern, replacement)
      when is_binary(s) and is_binary(pattern) and is_binary(replacement) do
    String.replace(s, pattern, replacement)
  end
end
