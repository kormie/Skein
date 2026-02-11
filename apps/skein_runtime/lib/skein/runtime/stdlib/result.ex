defmodule Skein.Runtime.Stdlib.Result do
  @moduledoc """
  Standard library functions for the Skein `Result` type.

  Results represent operations that can succeed or fail. They are encoded as
  `{:ok, value}` or `{:error, reason}` at runtime. Effect calls and parsing
  functions return Results.

  ## Examples (Skein)

      let r = Ok(42)
      Result.unwrap(r)                    -- 42
      Result.map(r, fn(n) { n + 1 })     -- Ok(43)
      Result.is_ok(r)                     -- true
  """

  @doc "Extracts the value from `Ok`. Raises if called on `Err`."
  @spec unwrap({:ok, any()} | {:error, any()}) :: any()
  def unwrap({:ok, value}), do: value
  def unwrap({:error, reason}), do: raise("unwrap called on Err: #{inspect(reason)}")

  @doc "Applies `func` to the success value. Passes `Err` through unchanged."
  @spec map({:ok, any()} | {:error, any()}, (any() -> any())) ::
          {:ok, any()} | {:error, any()}
  def map({:ok, value}, func) when is_function(func, 1), do: {:ok, func.(value)}
  def map({:error, _} = err, _func), do: err

  @doc "Applies `func` to the error value. Passes `Ok` through unchanged."
  @spec map_err({:ok, any()} | {:error, any()}, (any() -> any())) ::
          {:ok, any()} | {:error, any()}
  def map_err({:ok, _} = ok, _func), do: ok
  def map_err({:error, reason}, func) when is_function(func, 1), do: {:error, func.(reason)}

  @doc "Chains fallible operations. `func` must return a `Result`."
  @spec flat_map({:ok, any()} | {:error, any()}, (any() -> {:ok, any()} | {:error, any()})) ::
          {:ok, any()} | {:error, any()}
  def flat_map({:ok, value}, func) when is_function(func, 1), do: func.(value)
  def flat_map({:error, _} = err, _func), do: err

  @doc "Returns `true` if the value is `Ok`."
  @spec is_ok({:ok, any()} | {:error, any()}) :: boolean()
  def is_ok({:ok, _}), do: true
  def is_ok({:error, _}), do: false

  @doc "Returns `true` if the value is `Err`."
  @spec is_err({:ok, any()} | {:error, any()}) :: boolean()
  def is_err({:error, _}), do: true
  def is_err({:ok, _}), do: false

  @doc "Wraps `value` in `Ok`."
  @spec ok(any()) :: {:ok, any()}
  def ok(value), do: {:ok, value}

  @doc "Wraps `reason` in `Err`."
  @spec err(any()) :: {:error, any()}
  def err(reason), do: {:error, reason}
end
