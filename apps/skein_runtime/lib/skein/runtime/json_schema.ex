defmodule Skein.Runtime.JsonSchema do
  @moduledoc """
  The one recursive schema engine (C3/#298): validation + key atomization
  for JSON decoded against a Skein-derived JSON Schema.

  `validate/2` recursively enforces everything `Skein.CodeGen.SchemaGen`
  emits — nested objects (`properties`/`required`), arrays (`items`,
  `uniqueItems`), `additionalProperties` (Map[K, V]), scalar types,
  `format` (uuid/date-time/email/uri), `enum`, `minimum`/`maximum`, and
  enum-variant `oneOf` — returning human-readable violations with paths.

  `atomize/2` converts schema-declared string keys to atoms (compiled
  field access reads atom keys) and makes Option fields total
  ({:some, v}/:none). `decode/2` composes the two.

  Shared by `Skein.Runtime.Request` (`req.json[T]`), `Skein.Runtime.Llm`
  (`llm.json[T]`), and `Skein.Runtime.Tool` (input AND output), so every
  schema boundary enforces one contract.
  """

  @doc """
  Recursively validates `value` against `schema`.

  Returns `:ok` or `{:error, violations}` where each violation is a
  human-readable string carrying the field path (e.g.
  `"address.city: expected string"`). An empty schema is permissive
  (the `Json` type). Both string- and atom-keyed maps validate (internal
  values round-trip with atom keys), and already-tagged Option values
  ({:some, v} / :none) validate their inner value.
  """
  @spec validate(term(), map()) :: :ok | {:error, [String.t()]}
  def validate(value, schema) do
    case violations(value, schema, nil) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  @doc """
  Validates `value` against `schema`, then atomizes it (`atomize/2`).

  Returns `{:ok, decoded}` or `{:error, violations}`.
  """
  @spec decode(term(), map()) :: {:ok, term()} | {:error, [String.t()]}
  def decode(value, schema) do
    case validate(value, schema) do
      :ok -> {:ok, atomize(value, schema)}
      {:error, _} = error -> error
    end
  end

  # ------------------------------------------------------------------
  # Recursive validation
  # ------------------------------------------------------------------

  defp violations(_value, schema, _path) when map_size(schema) == 0, do: []

  # Already-tagged Option values (internal round trips): validate the inner.
  defp violations({:some, inner}, schema, path), do: violations(inner, schema, path)
  defp violations(:none, _schema, _path), do: []

  defp violations(value, %{"oneOf" => branches} = _schema, path) when is_list(branches) do
    if Enum.any?(branches, &(violations(value, &1, path) == [])) do
      []
    else
      [at(path, "matches no oneOf branch")]
    end
  end

  defp violations(value, %{"type" => "object"} = schema, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    required =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&has_key_flex?(value, &1))
      |> Enum.map(&at(path, "required field '#{&1}' is missing"))

    property_violations =
      Enum.flat_map(properties, fn {field, field_schema} ->
        case get_flex(value, field) do
          :missing -> []
          {:found, sub_value} -> violations(sub_value, field_schema, join(path, field))
        end
      end)

    additional =
      case Map.get(schema, "additionalProperties") do
        %{} = sub when map_size(sub) > 0 ->
          Enum.flat_map(value, fn {key, sub_value} ->
            violations(sub_value, sub, join(path, key_name(key)))
          end)

        _ ->
          []
      end

    required ++ property_violations ++ additional
  end

  defp violations(_value, %{"type" => "object"}, path), do: [at(path, "expected object")]

  defp violations(value, %{"type" => "array"} = schema, path) when is_list(value) do
    items_schema = Map.get(schema, "items", %{})

    element_violations =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {element, index} ->
        violations(element, items_schema, "#{path_or_value(path)}[#{index}]")
      end)

    unique_violations =
      if Map.get(schema, "uniqueItems", false) and length(Enum.uniq(value)) != length(value) do
        [at(path, "items must be unique")]
      else
        []
      end

    element_violations ++ unique_violations
  end

  defp violations(_value, %{"type" => "array"}, path), do: [at(path, "expected array")]

  defp violations(value, %{"type" => type} = schema, path) do
    case scalar_type_violation(value, type, path) do
      [] -> constraint_violations(value, schema, path)
      type_violation -> type_violation
    end
  end

  # No "type" (e.g. a bare "const" property or unconstrained schema).
  defp violations(value, %{} = schema, path) do
    constraint_violations(value, schema, path)
  end

  defp scalar_type_violation(value, "string", _path) when is_binary(value), do: []
  defp scalar_type_violation(_value, "string", path), do: [at(path, "expected string")]
  defp scalar_type_violation(value, "integer", _path) when is_integer(value), do: []
  defp scalar_type_violation(_value, "integer", path), do: [at(path, "expected integer")]
  defp scalar_type_violation(value, "number", _path) when is_number(value), do: []
  defp scalar_type_violation(_value, "number", path), do: [at(path, "expected number")]
  defp scalar_type_violation(value, "boolean", _path) when is_boolean(value), do: []
  defp scalar_type_violation(_value, "boolean", path), do: [at(path, "expected boolean")]
  defp scalar_type_violation(_value, _other, _path), do: []

  @uuid_pattern ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  defp constraint_violations(value, schema, path) do
    Enum.flat_map(schema, fn
      {"enum", allowed} when is_list(allowed) ->
        if value in allowed,
          do: [],
          else: [at(path, "must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}")]

      {"const", expected} ->
        if value == expected, do: [], else: [at(path, "must equal #{inspect(expected)}")]

      {"minimum", min} when is_number(value) ->
        if value >= min, do: [], else: [at(path, "must be >= #{min}")]

      {"maximum", max} when is_number(value) ->
        if value <= max, do: [], else: [at(path, "must be <= #{max}")]

      {"format", format} when is_binary(value) ->
        format_violation(value, format, path)

      _ ->
        []
    end)
  end

  defp format_violation(value, "uuid", path) do
    if value =~ @uuid_pattern, do: [], else: [at(path, "expected a uuid")]
  end

  defp format_violation(value, "date-time", path) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> []
      _ -> [at(path, "expected a date-time (ISO 8601)")]
    end
  end

  defp format_violation(value, "email", path) do
    if value =~ ~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/,
      do: [],
      else: [at(path, "expected an email address")]
  end

  defp format_violation(value, "uri", path) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> []
      _ -> [at(path, "expected a URI")]
    end
  end

  defp format_violation(_value, _other, _path), do: []

  defp has_key_flex?(map, key) when is_binary(key) do
    Map.has_key?(map, key) or
      (safe_existing_atom(key) != nil and Map.has_key?(map, safe_existing_atom(key)))
  end

  defp get_flex(map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        {:found, Map.get(map, key)}

      safe_existing_atom(key) != nil and Map.has_key?(map, safe_existing_atom(key)) ->
        {:found, Map.get(map, safe_existing_atom(key))}

      true ->
        :missing
    end
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp join(nil, field), do: key_name(field)
  defp join(path, field), do: "#{path}.#{key_name(field)}"

  defp at(nil, message), do: message
  defp at(path, message), do: "#{path}: #{message}"

  defp path_or_value(nil), do: "value"
  defp path_or_value(path), do: path

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
    # Atomize the present, schema-declared keys (coercing Option fields to
    # Some(v)), pass extra wire keys through unchanged, then inject None for
    # any absent Option-declared field so `match body.f { Some(s) -> ; None }`
    # never hits a missing atom key (skein-testing#32). Keys may already be
    # atoms when the map is internal rather than wire data — tool outputs
    # coerce through the same walk (#294) — so property lookup accepts both.
    present =
      Map.new(value, fn {key, sub_value} ->
        case fetch_property(properties, key) do
          {:ok, sub_schema} -> {atom_key(key), coerce_field(sub_value, sub_schema)}
          :error -> {key, sub_value}
        end
      end)

    present_names = MapSet.new(Map.keys(value), &key_name/1)

    Enum.reduce(properties, present, fn {field, sub_schema}, acc ->
      if optional?(sub_schema) and not MapSet.member?(present_names, field) do
        Map.put(acc, atom_key(field), :none)
      else
        acc
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

  # A present field value: a declared Option field is wrapped in Some(v) (the
  # tuple {:some, _} the codegen matches), everything else recurses normally.
  # Already-tagged values pass through — internal maps (tool outputs) may
  # carry them, and wire JSON can never produce these tuples.
  defp coerce_field({:some, _} = value, _sub_schema), do: value
  defp coerce_field(:none, _sub_schema), do: :none

  defp coerce_field(value, sub_schema) do
    if optional?(sub_schema) do
      {:some, atomize(value, sub_schema)}
    else
      atomize(value, sub_schema)
    end
  end

  defp optional?(%{"x-skein-optional" => true}), do: true
  defp optional?(_), do: false

  defp fetch_property(properties, key) when is_binary(key), do: Map.fetch(properties, key)

  defp fetch_property(properties, key) when is_atom(key),
    do: Map.fetch(properties, Atom.to_string(key))

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: key

  # A field name is already an atom only when it survived a previous pass;
  # string keys from the wire are interned against the closed schema set.
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end
