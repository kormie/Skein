defmodule Skein.Runtime.Stdlib.List do
  @moduledoc """
  Standard library functions for the Skein `List` type.

  Lists are ordered, heterogeneous sequences. In Skein source code these
  are called as `List.map(items, fn(x) { x * 2 })`, etc.

  ## Examples (Skein)

      let nums = [1, 2, 3, 4, 5]
      List.map(nums, fn(x) { x * 2 })       -- [2, 4, 6, 8, 10]
      List.filter(nums, fn(x) { x > 3 })    -- [4, 5]
      List.reduce(nums, 0, fn(acc, x) { acc + x }) -- 15
  """

  @doc "Returns the number of elements in `list`."
  @spec length(list()) :: non_neg_integer()
  def length(list) when is_list(list), do: Kernel.length(list)

  @doc "Applies `func` to each element and returns the list of results."
  @spec map(list(), (any() -> any())) :: list()
  def map(list, func) when is_list(list) and is_function(func, 1) do
    Enum.map(list, func)
  end

  @doc "Returns only elements for which `func` returns `true`."
  @spec filter(list(), (any() -> boolean())) :: list()
  def filter(list, func) when is_list(list) and is_function(func, 1) do
    Enum.filter(list, func)
  end

  @doc "Folds `list` from the left using `initial` as the starting accumulator."
  @spec reduce(list(), any(), (any(), any() -> any())) :: any()
  def reduce(list, initial, func) when is_list(list) and is_function(func, 2) do
    # Spec §5.4: the callback is `f(acc, element)` — accumulator first. Elixir's
    # `Enum.reduce/3` invokes `fun.(element, acc)`, so adapt the order here rather
    # than threading the raw callback (which silently reversed the fold).
    Enum.reduce(list, initial, fn element, acc -> func.(acc, element) end)
  end

  @doc "Returns `{:some, element}` for the first element matching `func`, or `:none`."
  @spec find(list(), (any() -> boolean())) :: {:some, any()} | :none
  def find(list, func) when is_list(list) and is_function(func, 1) do
    case Enum.find(list, nil, func) do
      nil -> :none
      val -> {:some, val}
    end
  end

  @doc "Returns `{:some, element}` for the first element, or `:none` if empty."
  @spec first(list()) :: {:some, any()} | :none
  def first([]), do: :none
  def first([h | _]), do: {:some, h}

  @doc "Returns `{:some, element}` for the last element, or `:none` if empty."
  @spec last(list()) :: {:some, any()} | :none
  def last([]), do: :none
  def last(list) when is_list(list), do: {:some, List.last(list)}

  @doc "Alias for `first/1`. Returns `{:some, element}` for the head, or `:none`."
  @spec head(list()) :: {:some, any()} | :none
  def head([]), do: :none
  def head([h | _]), do: {:some, h}

  @doc "Returns all elements except the first. Returns `[]` for an empty list."
  @spec tail(list()) :: list()
  def tail([]), do: []
  def tail([_ | t]), do: t

  @doc "Returns the first `n` elements of `list`."
  @spec take(list(), non_neg_integer()) :: list()
  def take(list, n) when is_list(list) and is_integer(n), do: Enum.take(list, n)

  @doc "Returns `list` with the first `n` elements removed."
  @spec drop(list(), non_neg_integer()) :: list()
  def drop(list, n) when is_list(list) and is_integer(n), do: Enum.drop(list, n)

  @doc "Sorts `list` in ascending order using default comparison."
  @spec sort(list()) :: list()
  def sort(list) when is_list(list), do: Enum.sort(list)

  @doc "Sorts `list` by the value returned by `func` for each element."
  @spec sort_by(list(), (any() -> any())) :: list()
  def sort_by(list, func) when is_list(list) and is_function(func, 1) do
    Enum.sort_by(list, func)
  end

  @doc "Reverses the order of elements in `list`."
  @spec reverse(list()) :: list()
  def reverse(list) when is_list(list), do: Enum.reverse(list)

  @doc "Flattens one level of nesting in `list`."
  @spec flatten(list()) :: list()
  def flatten(list) when is_list(list), do: List.flatten(list)

  @doc "Concatenates two lists."
  @spec concat(list(), list()) :: list()
  def concat(a, b) when is_list(a) and is_list(b), do: a ++ b

  @doc "Returns `true` if `item` is a member of `list`."
  @spec contains(list(), any()) :: boolean()
  def contains(list, item) when is_list(list), do: Enum.member?(list, item)

  @doc "Returns `true` if `func` returns `true` for any element."
  @spec any(list(), (any() -> boolean())) :: boolean()
  def any(list, func) when is_list(list) and is_function(func, 1) do
    Enum.any?(list, func)
  end

  @doc "Returns `true` if `func` returns `true` for every element."
  @spec all(list(), (any() -> boolean())) :: boolean()
  def all(list, func) when is_list(list) and is_function(func, 1) do
    Enum.all?(list, func)
  end

  @doc "Returns `true` if `func` returns `false` for every element."
  @spec none(list(), (any() -> boolean())) :: boolean()
  def none(list, func) when is_list(list) and is_function(func, 1) do
    not Enum.any?(list, func)
  end

  @doc "Pairs elements from two lists into `[a, b]` sub-lists."
  @spec zip(list(), list()) :: list()
  def zip(a, b) when is_list(a) and is_list(b) do
    Enum.zip(a, b) |> Enum.map(fn {x, y} -> [x, y] end)
  end

  @doc "Removes duplicate elements, keeping the first occurrence."
  @spec uniq(list()) :: list()
  def uniq(list) when is_list(list), do: Enum.uniq(list)

  @doc "Counts elements for which `func` returns `true`."
  @spec count(list(), (any() -> boolean())) :: non_neg_integer()
  def count(list, func) when is_list(list) and is_function(func, 1) do
    Enum.count(list, func)
  end

  @doc "Groups elements by the key returned by `func`."
  @spec group_by(list(), (any() -> any())) :: map()
  def group_by(list, func) when is_list(list) and is_function(func, 1) do
    Enum.group_by(list, func)
  end
end
