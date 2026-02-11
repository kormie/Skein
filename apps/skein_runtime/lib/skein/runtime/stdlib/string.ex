defmodule Skein.Runtime.Stdlib.String do
  @moduledoc """
  Standard library functions for the Skein `String` type.

  All functions operate on UTF-8 binaries. In Skein source code these are
  called as `String.length(s)`, `String.upcase(s)`, etc.

  ## Examples (Skein)

      let name = "  Hello, World!  "
      String.trim(name)            -- "Hello, World!"
      String.upcase("hello")       -- "HELLO"
      String.split("a,b,c", ",")  -- ["a", "b", "c"]
  """

  @doc "Returns the number of Unicode graphemes in `s`."
  @spec length(binary()) :: non_neg_integer()
  def length(s) when is_binary(s) do
    String.length(s)
  end

  @doc "Returns a substring of `s` starting at `start` with the given `len`."
  @spec slice(binary(), integer(), non_neg_integer()) :: binary()
  def slice(s, start, len) when is_binary(s) and is_integer(start) and is_integer(len) do
    String.slice(s, start, len)
  end

  @doc "Returns `true` if `s` contains the substring `sub`."
  @spec contains(binary(), binary()) :: boolean()
  def contains(s, sub) when is_binary(s) and is_binary(sub) do
    String.contains?(s, sub)
  end

  @doc "Splits `s` on every occurrence of `delimiter` and returns a list of parts."
  @spec split(binary(), binary()) :: [binary()]
  def split(s, delimiter) when is_binary(s) and is_binary(delimiter) do
    String.split(s, delimiter)
  end

  @doc "Removes leading and trailing whitespace from `s`."
  @spec trim(binary()) :: binary()
  def trim(s) when is_binary(s) do
    String.trim(s)
  end

  @doc "Converts all characters in `s` to uppercase."
  @spec upcase(binary()) :: binary()
  def upcase(s) when is_binary(s) do
    String.upcase(s)
  end

  @doc "Converts all characters in `s` to lowercase."
  @spec downcase(binary()) :: binary()
  def downcase(s) when is_binary(s) do
    String.downcase(s)
  end

  @doc "Returns `true` if `s` starts with `prefix`."
  @spec starts_with(binary(), binary()) :: boolean()
  def starts_with(s, prefix) when is_binary(s) and is_binary(prefix) do
    String.starts_with?(s, prefix)
  end

  @doc "Returns `true` if `s` ends with `suffix`."
  @spec ends_with(binary(), binary()) :: boolean()
  def ends_with(s, suffix) when is_binary(s) and is_binary(suffix) do
    String.ends_with?(s, suffix)
  end

  @doc "Replaces all occurrences of `pattern` in `s` with `replacement`."
  @spec replace(binary(), binary(), binary()) :: binary()
  def replace(s, pattern, replacement)
      when is_binary(s) and is_binary(pattern) and is_binary(replacement) do
    String.replace(s, pattern, replacement)
  end
end
