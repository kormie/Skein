defmodule Skein.Runtime.Stdlib.Result do
  @moduledoc """
  Standard library functions for the Skein `Result` type.

  Results are represented as `{:ok, value}` or `{:error, reason}`.
  """

  @spec unwrap({:ok, any()} | {:error, any()}) :: any()
  def unwrap({:ok, value}), do: value
  def unwrap({:error, reason}), do: raise("unwrap called on Err: #{inspect(reason)}")

  @spec map({:ok, any()} | {:error, any()}, (any() -> any())) ::
          {:ok, any()} | {:error, any()}
  def map({:ok, value}, func) when is_function(func, 1), do: {:ok, func.(value)}
  def map({:error, _} = err, _func), do: err

  @spec map_err({:ok, any()} | {:error, any()}, (any() -> any())) ::
          {:ok, any()} | {:error, any()}
  def map_err({:ok, _} = ok, _func), do: ok
  def map_err({:error, reason}, func) when is_function(func, 1), do: {:error, func.(reason)}

  @spec flat_map({:ok, any()} | {:error, any()}, (any() -> {:ok, any()} | {:error, any()})) ::
          {:ok, any()} | {:error, any()}
  def flat_map({:ok, value}, func) when is_function(func, 1), do: func.(value)
  def flat_map({:error, _} = err, _func), do: err

  @spec is_ok({:ok, any()} | {:error, any()}) :: boolean()
  def is_ok({:ok, _}), do: true
  def is_ok({:error, _}), do: false

  @spec is_err({:ok, any()} | {:error, any()}) :: boolean()
  def is_err({:error, _}), do: true
  def is_err({:ok, _}), do: false

  @spec ok(any()) :: {:ok, any()}
  def ok(value), do: {:ok, value}

  @spec err(any()) :: {:error, any()}
  def err(reason), do: {:error, reason}
end
