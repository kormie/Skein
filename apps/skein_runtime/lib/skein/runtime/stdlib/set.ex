defmodule Skein.Runtime.Stdlib.Set do
  @moduledoc """
  Standard library functions for the Skein `Set` type.

  Sets are backed by MapSet in the BEAM runtime.
  """

  @spec from(list()) :: MapSet.t()
  def from(list) when is_list(list), do: MapSet.new(list)

  @spec add(MapSet.t(), any()) :: MapSet.t()
  def add(set, item), do: MapSet.put(set, item)

  @spec remove(MapSet.t(), any()) :: MapSet.t()
  def remove(set, item), do: MapSet.delete(set, item)

  @spec contains(MapSet.t(), any()) :: boolean()
  def contains(set, item), do: MapSet.member?(set, item)

  @spec size(MapSet.t()) :: non_neg_integer()
  def size(set), do: MapSet.size(set)

  @spec union(MapSet.t(), MapSet.t()) :: MapSet.t()
  def union(a, b), do: MapSet.union(a, b)

  @spec intersection(MapSet.t(), MapSet.t()) :: MapSet.t()
  def intersection(a, b), do: MapSet.intersection(a, b)

  @spec difference(MapSet.t(), MapSet.t()) :: MapSet.t()
  def difference(a, b), do: MapSet.difference(a, b)

  @spec to_list(MapSet.t()) :: list()
  def to_list(set), do: MapSet.to_list(set)
end
