defmodule Skein.Runtime.Stdlib.Map do
  @moduledoc """
  Standard library functions for the Skein `Map` type.

  Maps are unordered collections of unique keys to values. In Skein source
  code these are called as `Map.get(m, "key")`, `Map.put(m, "key", val)`, etc.

  ## Examples (Skein)

      let m = Map.put({}, "name", "Alice")
      Map.get(m, "name")        -- Some("Alice")
      Map.keys(m)               -- ["name"]
      Map.has(m, "email")       -- false

  Record literals like `{ name: "Alice" }` compile with atom keys, which do
  not match the string keys used by `Map.get`/`Map.has`; build string-keyed
  maps with `Map.put` for keyed lookups.
  """

  @doc "Returns `{:some, value}` if `key` exists, or `:none`."
  @spec get(map(), any()) :: {:some, any()} | :none
  def get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> {:some, val}
      :error -> :none
    end
  end

  @doc "Inserts or updates `key` with `value` in `map`."
  @spec put(map(), any(), any()) :: map()
  def put(map, key, value) when is_map(map) do
    Map.put(map, key, value)
  end

  @doc "Removes `key` from `map`. Returns `map` unchanged if key is absent."
  @spec delete(map(), any()) :: map()
  def delete(map, key) when is_map(map) do
    Map.delete(map, key)
  end

  @doc "Returns a list of all keys in `map`."
  @spec keys(map()) :: list()
  def keys(map) when is_map(map), do: Map.keys(map)

  @doc "Returns a list of all values in `map`."
  @spec values(map()) :: list()
  def values(map) when is_map(map), do: Map.values(map)

  @doc "Returns all key-value pairs as a list of `[key, value]` sub-lists."
  @spec entries(map()) :: list()
  def entries(map) when is_map(map) do
    Map.to_list(map) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  @doc "Returns the number of entries in `map`."
  @spec size(map()) :: non_neg_integer()
  def size(map) when is_map(map), do: map_size(map)

  @doc "Returns `true` if `key` exists in `map`."
  @spec has(map(), any()) :: boolean()
  def has(map, key) when is_map(map), do: Map.has_key?(map, key)

  @doc "Merges two maps. Values from the second map win on key conflicts."
  @spec merge(map(), map()) :: map()
  def merge(a, b) when is_map(a) and is_map(b), do: Map.merge(a, b)

  @doc "Applies `func` to every value in `map`, keeping keys unchanged."
  @spec map_values(map(), (any() -> any())) :: map()
  def map_values(map, func) when is_map(map) and is_function(func, 1) do
    Map.new(map, fn {k, v} -> {k, func.(v)} end)
  end

  @doc "Keeps only entries for which `func.(key, value)` returns `true`."
  @spec filter(map(), (any(), any() -> boolean())) :: map()
  def filter(map, func) when is_map(map) and is_function(func, 2) do
    Map.filter(map, fn {k, v} -> func.(k, v) end)
  end
end
