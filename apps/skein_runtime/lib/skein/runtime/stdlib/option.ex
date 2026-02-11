defmodule Skein.Runtime.Stdlib.Option do
  @moduledoc """
  Standard library functions for the Skein `Option` type.

  Options represent values that may or may not exist. They are encoded as
  `{:some, value}` or `:none` at runtime. Functions like `List.find` and
  `Map.get` return Options.

  ## Examples (Skein)

      let x = Some(42)
      Option.unwrap(x)                    -- 42
      Option.map(x, fn(n) { n + 1 })     -- Some(43)
      Option.is_some(x)                   -- true
  """

  @doc "Extracts the value from `Some`. Raises if called on `None`."
  @spec unwrap({:some, any()} | :none) :: any()
  def unwrap({:some, value}), do: value
  def unwrap(:none), do: raise("unwrap called on None")

  @doc "Applies `func` to the inner value if `Some`, passes `None` through."
  @spec map({:some, any()} | :none, (any() -> any())) :: {:some, any()} | :none
  def map({:some, value}, func) when is_function(func, 1), do: {:some, func.(value)}
  def map(:none, _func), do: :none

  @doc "Chains optional operations. `func` must return an `Option`."
  @spec flat_map({:some, any()} | :none, (any() -> {:some, any()} | :none)) ::
          {:some, any()} | :none
  def flat_map({:some, value}, func) when is_function(func, 1), do: func.(value)
  def flat_map(:none, _func), do: :none

  @doc "Returns `true` if the value is `Some`."
  @spec is_some({:some, any()} | :none) :: boolean()
  def is_some({:some, _}), do: true
  def is_some(:none), do: false

  @doc "Returns `true` if the value is `None`."
  @spec is_none({:some, any()} | :none) :: boolean()
  def is_none(:none), do: true
  def is_none({:some, _}), do: false
end
