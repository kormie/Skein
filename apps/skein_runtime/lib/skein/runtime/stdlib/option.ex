defmodule Skein.Runtime.Stdlib.Option do
  @moduledoc """
  Standard library functions for the Skein `Option` type.

  Options are represented as `{:some, value}` or `:none`.
  """

  @spec unwrap({:some, any()} | :none) :: any()
  def unwrap({:some, value}), do: value
  def unwrap(:none), do: raise("unwrap called on None")

  @spec map({:some, any()} | :none, (any() -> any())) :: {:some, any()} | :none
  def map({:some, value}, func) when is_function(func, 1), do: {:some, func.(value)}
  def map(:none, _func), do: :none

  @spec flat_map({:some, any()} | :none, (any() -> {:some, any()} | :none)) ::
          {:some, any()} | :none
  def flat_map({:some, value}, func) when is_function(func, 1), do: func.(value)
  def flat_map(:none, _func), do: :none

  @spec is_some({:some, any()} | :none) :: boolean()
  def is_some({:some, _}), do: true
  def is_some(:none), do: false

  @spec is_none({:some, any()} | :none) :: boolean()
  def is_none(:none), do: true
  def is_none({:some, _}), do: false
end
