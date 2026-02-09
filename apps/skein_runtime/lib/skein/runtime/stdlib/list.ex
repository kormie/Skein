defmodule Skein.Runtime.Stdlib.List do
  @moduledoc """
  Standard library functions for the Skein `List` type.
  """

  @spec length(list()) :: non_neg_integer()
  def length(list) when is_list(list), do: Kernel.length(list)

  @spec map(list(), (any() -> any())) :: list()
  def map(list, func) when is_list(list) and is_function(func, 1) do
    Enum.map(list, func)
  end

  @spec filter(list(), (any() -> boolean())) :: list()
  def filter(list, func) when is_list(list) and is_function(func, 1) do
    Enum.filter(list, func)
  end

  @spec reduce(list(), any(), (any(), any() -> any())) :: any()
  def reduce(list, initial, func) when is_list(list) and is_function(func, 2) do
    Enum.reduce(list, initial, func)
  end

  @spec find(list(), (any() -> boolean())) :: {:some, any()} | :none
  def find(list, func) when is_list(list) and is_function(func, 1) do
    case Enum.find(list, nil, func) do
      nil -> :none
      val -> {:some, val}
    end
  end

  @spec first(list()) :: {:some, any()} | :none
  def first([]), do: :none
  def first([h | _]), do: {:some, h}

  @spec last(list()) :: {:some, any()} | :none
  def last([]), do: :none
  def last(list) when is_list(list), do: {:some, List.last(list)}

  @spec head(list()) :: {:some, any()} | :none
  def head([]), do: :none
  def head([h | _]), do: {:some, h}

  @spec tail(list()) :: list()
  def tail([]), do: []
  def tail([_ | t]), do: t

  @spec take(list(), non_neg_integer()) :: list()
  def take(list, n) when is_list(list) and is_integer(n), do: Enum.take(list, n)

  @spec drop(list(), non_neg_integer()) :: list()
  def drop(list, n) when is_list(list) and is_integer(n), do: Enum.drop(list, n)

  @spec sort(list()) :: list()
  def sort(list) when is_list(list), do: Enum.sort(list)

  @spec sort_by(list(), (any() -> any())) :: list()
  def sort_by(list, func) when is_list(list) and is_function(func, 1) do
    Enum.sort_by(list, func)
  end

  @spec reverse(list()) :: list()
  def reverse(list) when is_list(list), do: Enum.reverse(list)

  @spec flatten(list()) :: list()
  def flatten(list) when is_list(list), do: List.flatten(list)

  @spec concat(list(), list()) :: list()
  def concat(a, b) when is_list(a) and is_list(b), do: a ++ b

  @spec contains(list(), any()) :: boolean()
  def contains(list, item) when is_list(list), do: Enum.member?(list, item)

  @spec any(list(), (any() -> boolean())) :: boolean()
  def any(list, func) when is_list(list) and is_function(func, 1) do
    Enum.any?(list, func)
  end

  @spec all(list(), (any() -> boolean())) :: boolean()
  def all(list, func) when is_list(list) and is_function(func, 1) do
    Enum.all?(list, func)
  end

  @spec none(list(), (any() -> boolean())) :: boolean()
  def none(list, func) when is_list(list) and is_function(func, 1) do
    not Enum.any?(list, func)
  end

  @spec zip(list(), list()) :: list()
  def zip(a, b) when is_list(a) and is_list(b) do
    Enum.zip(a, b) |> Enum.map(fn {x, y} -> [x, y] end)
  end

  @spec uniq(list()) :: list()
  def uniq(list) when is_list(list), do: Enum.uniq(list)

  @spec count(list(), (any() -> boolean())) :: non_neg_integer()
  def count(list, func) when is_list(list) and is_function(func, 1) do
    Enum.count(list, func)
  end

  @spec group_by(list(), (any() -> any())) :: map()
  def group_by(list, func) when is_list(list) and is_function(func, 1) do
    Enum.group_by(list, func)
  end
end
