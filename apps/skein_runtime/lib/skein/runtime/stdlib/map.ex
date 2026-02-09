defmodule Skein.Runtime.Stdlib.Map do
  @moduledoc """
  Standard library functions for the Skein `Map` type.
  """

  @spec get(map(), any()) :: {:some, any()} | :none
  def get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> {:some, val}
      :error -> :none
    end
  end

  @doc "get! raises on missing key"
  @spec get!(map(), any()) :: any()
  def get!(map, key) when is_map(map) do
    Map.fetch!(map, key)
  end

  @spec put(map(), any(), any()) :: map()
  def put(map, key, value) when is_map(map) do
    Map.put(map, key, value)
  end

  @spec delete(map(), any()) :: map()
  def delete(map, key) when is_map(map) do
    Map.delete(map, key)
  end

  @spec keys(map()) :: list()
  def keys(map) when is_map(map), do: Map.keys(map)

  @spec values(map()) :: list()
  def values(map) when is_map(map), do: Map.values(map)

  @spec entries(map()) :: list()
  def entries(map) when is_map(map) do
    Map.to_list(map) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  @spec size(map()) :: non_neg_integer()
  def size(map) when is_map(map), do: map_size(map)

  @spec has(map(), any()) :: boolean()
  def has(map, key) when is_map(map), do: Map.has_key?(map, key)

  @spec merge(map(), map()) :: map()
  def merge(a, b) when is_map(a) and is_map(b), do: Map.merge(a, b)

  @spec map_values(map(), (any() -> any())) :: map()
  def map_values(map, func) when is_map(map) and is_function(func, 1) do
    Map.new(map, fn {k, v} -> {k, func.(v)} end)
  end

  @spec filter(map(), (any(), any() -> boolean())) :: map()
  def filter(map, func) when is_map(map) and is_function(func, 2) do
    Map.filter(map, fn {k, v} -> func.(k, v) end)
  end
end
