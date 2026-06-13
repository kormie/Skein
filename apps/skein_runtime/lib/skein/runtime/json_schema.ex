defmodule Skein.Runtime.JsonSchema do
  @moduledoc """
  Schema-directed key atomization for decoded JSON.

  Backends and request bodies decode JSON with string keys, but compiled
  Skein field access reads atom keys (`d.action` -> `map_get(:action, d)`).
  The JSON Schema derived from `T` (in `llm.json[T]` / `req.json[T]`)
  closes the set of declared field names, so atomizing exactly those names
  is safe: wire data outside the schema never reaches `String.to_atom` and
  passes through unchanged.

  Shared by `Skein.Runtime.Llm` and `Skein.Runtime.Request` so the LLM and
  HTTP JSON paths coerce keys identically.
  """

  @doc """
  Recursively converts schema-declared string keys to atoms in `value`.
  """
  @spec atomize(term(), map()) :: term()
  # Enum variants (`oneOf`): atomize against the branch whose "type" const
  # matches the value's discriminator.
  def atomize(%{} = value, %{"oneOf" => branches}) do
    discriminator = Map.get(value, "type")

    case Enum.find(branches, &(get_in(&1, ["properties", "type", "const"]) == discriminator)) do
      nil -> value
      branch -> atomize(value, branch)
    end
  end

  def atomize(%{} = value, %{"type" => "object", "properties" => properties}) do
    Map.new(value, fn {key, sub_value} ->
      case Map.fetch(properties, key) do
        {:ok, sub_schema} -> {atom_key(key), atomize(sub_value, sub_schema)}
        :error -> {key, sub_value}
      end
    end)
  end

  # Map[K, V] (`additionalProperties`): keys are data, not field names —
  # they stay strings; only the values' declared fields atomize.
  def atomize(%{} = value, %{"type" => "object", "additionalProperties" => sub}) do
    Map.new(value, fn {key, sub_value} -> {key, atomize(sub_value, sub)} end)
  end

  def atomize(value, %{"type" => "array", "items" => items}) when is_list(value) do
    Enum.map(value, &atomize(&1, items))
  end

  def atomize(value, _schema), do: value

  # A field name is already an atom only when it survived a previous pass;
  # string keys from the wire are interned against the closed schema set.
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end
