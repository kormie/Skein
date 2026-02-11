defmodule Skein.Runtime.Stdlib.Set do
  @moduledoc """
  Standard library functions for the Skein `Set` type.

  Sets are unordered collections of unique values, backed by `MapSet` in
  the BEAM runtime. In Skein source code these are called as
  `Set.from([1, 2, 3])`, `Set.contains(s, 2)`, etc.

  ## Examples (Skein)

      let s = Set.from([1, 2, 3])
      Set.contains(s, 2)               -- true
      Set.union(s, Set.from([3, 4]))   -- Set{1, 2, 3, 4}
      Set.size(s)                      -- 3
  """

  @doc "Creates a set from a list, removing duplicates."
  @spec from(list()) :: MapSet.t()
  def from(list) when is_list(list), do: MapSet.new(list)

  @doc "Adds `item` to `set`."
  @spec add(MapSet.t(), any()) :: MapSet.t()
  def add(set, item), do: MapSet.put(set, item)

  @doc "Removes `item` from `set`. Returns `set` unchanged if absent."
  @spec remove(MapSet.t(), any()) :: MapSet.t()
  def remove(set, item), do: MapSet.delete(set, item)

  @doc "Returns `true` if `item` is a member of `set`."
  @spec contains(MapSet.t(), any()) :: boolean()
  def contains(set, item), do: MapSet.member?(set, item)

  @doc "Returns the number of elements in `set`."
  @spec size(MapSet.t()) :: non_neg_integer()
  def size(set), do: MapSet.size(set)

  @doc "Returns the union of two sets (all elements from both)."
  @spec union(MapSet.t(), MapSet.t()) :: MapSet.t()
  def union(a, b), do: MapSet.union(a, b)

  @doc "Returns the intersection of two sets (elements present in both)."
  @spec intersection(MapSet.t(), MapSet.t()) :: MapSet.t()
  def intersection(a, b), do: MapSet.intersection(a, b)

  @doc "Returns elements in the first set that are not in the second."
  @spec difference(MapSet.t(), MapSet.t()) :: MapSet.t()
  def difference(a, b), do: MapSet.difference(a, b)

  @doc "Converts `set` to a list."
  @spec to_list(MapSet.t()) :: list()
  def to_list(set), do: MapSet.to_list(set)
end
