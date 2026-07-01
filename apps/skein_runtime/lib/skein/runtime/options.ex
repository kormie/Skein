defmodule Skein.Runtime.Options do
  @moduledoc """
  Converts the in-language Option representation to the wire representation
  at serialization boundaries (#294).

  In-language, optional record fields are total: present values are
  `{:some, v}` and absent ones are `:none` — identically for nominal
  construction, JSON decode (`Skein.Runtime.JsonSchema.atomize/2`), store
  reads, and tool outputs. On the JSON wire the same fields are bare values
  and absent keys. `strip/1` performs the in-language → wire direction;
  `atomize/2` performs the inverse on decode.
  """

  @doc """
  Deeply converts `{:some, v}` to `v` and drops `:none`-valued map keys
  (a top-level or list-element `:none` becomes `nil`, since there is no
  key to omit). Maps and lists are walked recursively; everything else
  passes through unchanged.
  """
  @spec strip(any()) :: any()
  def strip({:some, value}), do: strip(value)
  def strip(:none), do: nil

  # Structs (DateTime for Instant columns, ...) are scalars on this wire —
  # Jason has encoders for them; walking their fields would corrupt them.
  def strip(%_{} = struct), do: struct

  def strip(%{} = map) do
    map
    |> Enum.reject(fn {_key, value} -> value == :none end)
    |> Map.new(fn {key, value} -> {key, strip(value)} end)
  end

  def strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  def strip(other), do: other
end
