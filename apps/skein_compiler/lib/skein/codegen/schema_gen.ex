defmodule Skein.CodeGen.SchemaGen do
  @moduledoc """
  Generates JSON Schemas from Skein type declarations.

  Used for:
  - LLM tool calling manifests
  - HTTP request/response validation
  - LLM constrained decoding (llm.json[T])

  ## Schema Mapping

  | Skein Type | JSON Schema |
  |------------|-------------|
  | Int | `{"type": "integer"}` |
  | Float | `{"type": "number"}` |
  | String | `{"type": "string"}` |
  | Bool | `{"type": "boolean"}` |
  | Uuid | `{"type": "string", "format": "uuid"}` |
  | Instant | `{"type": "string", "format": "date-time"}` |
  | Duration | `{"type": "string"}` |
  | Email | `{"type": "string", "format": "email"}` |
  | Url | `{"type": "string", "format": "uri"}` |
  | List[T] | `{"type": "array", "items": T}` |
  | Set[T] | `{"type": "array", "uniqueItems": true, "items": T}` |
  | Map[K, V] | `{"type": "object"}` |
  | Option[T] | T's schema (field omitted from `required`) |
  """

  alias Skein.AST

  @spec to_json_schema(AST.TypeDecl.t(), map(), MapSet.t()) :: map()
  def to_json_schema(type_decl, env \\ %{}, seen \\ MapSet.new())

  def to_json_schema(%AST.TypeDecl{fields: fields}, env, seen) do
    fields_to_schema(fields, env, seen)
  end

  @doc """
  Generates a JSON Schema object from a list of `AST.Field` structs.

  Used by tool declarations and `llm.json[T]` to derive schemas from
  field lists without requiring a full `TypeDecl`.
  """
  @spec fields_to_schema([AST.Field.t()], map(), MapSet.t()) :: map()
  def fields_to_schema(fields, env \\ %{}, seen \\ MapSet.new()) when is_list(fields) do
    properties =
      fields
      |> Map.new(fn %AST.Field{name: name, type: type, annotations: annotations} ->
        schema = type_to_schema(type, env, seen)
        schema = apply_annotations(schema, annotations)
        {name, schema}
      end)

    required =
      fields
      |> Enum.reject(&is_optional?/1)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  @spec enum_to_schema(AST.EnumDecl.t(), map(), MapSet.t()) :: map()
  def enum_to_schema(enum_decl, env \\ %{}, seen \\ MapSet.new())

  def enum_to_schema(%AST.EnumDecl{variants: variants}, env, seen) do
    has_data_variants = Enum.any?(variants, fn v -> v.fields != [] end)

    if has_data_variants do
      one_of =
        variants
        |> Enum.map(fn %AST.Variant{name: name, fields: fields} ->
          type_prop = %{"type" => %{"const" => name}}

          if fields == [] do
            %{
              "type" => "object",
              "properties" => type_prop,
              "required" => ["type"]
            }
          else
            field_schemas =
              fields
              |> Map.new(fn %AST.Field{name: fname, type: ftype, annotations: anns} ->
                schema = type_to_schema(ftype, env, seen)
                schema = apply_annotations(schema, anns)
                {fname, schema}
              end)

            required =
              fields
              |> Enum.reject(&is_optional?/1)
              |> Enum.map(& &1.name)
              |> Enum.sort()

            %{
              "type" => "object",
              "properties" => Map.merge(type_prop, field_schemas),
              "required" => Enum.sort(["type" | required])
            }
          end
        end)
        |> Enum.sort_by(fn v -> v["properties"]["type"]["const"] end)

      %{"oneOf" => one_of}
    else
      values =
        variants
        |> Enum.map(& &1.name)
        |> Enum.sort()

      %{
        "type" => "string",
        "enum" => values
      }
    end
  end

  @spec to_json(AST.TypeDecl.t()) :: String.t()
  def to_json(%AST.TypeDecl{} = type_decl) do
    type_decl
    |> to_json_schema()
    |> Jason.encode!()
  end

  @spec type_to_schema(AST.TypeRef.t(), map(), MapSet.t()) :: map()
  def type_to_schema(type_ref, env \\ %{}, seen \\ MapSet.new())

  def type_to_schema(%AST.TypeRef{name: name, params: params}, env, seen) do
    case {name, params} do
      {"Int", []} ->
        %{"type" => "integer"}

      {"Float", []} ->
        %{"type" => "number"}

      {"String", []} ->
        %{"type" => "string"}

      {"Bool", []} ->
        %{"type" => "boolean"}

      {"Uuid", []} ->
        %{"type" => "string", "format" => "uuid"}

      {"Instant", []} ->
        %{"type" => "string", "format" => "date-time"}

      {"Duration", []} ->
        %{"type" => "string"}

      {"Email", []} ->
        %{"type" => "string", "format" => "email"}

      {"Url", []} ->
        %{"type" => "string", "format" => "uri"}

      {"List", [elem]} ->
        %{"type" => "array", "items" => type_to_schema(elem, env, seen)}

      {"Set", [elem]} ->
        %{"type" => "array", "uniqueItems" => true, "items" => type_to_schema(elem, env, seen)}

      {"Map", [_k, v]} ->
        %{"type" => "object", "additionalProperties" => type_to_schema(v, env, seen)}

      {"Option", [inner]} ->
        type_to_schema(inner, env, seen)

      {user_type, []} ->
        resolve_user_type(user_type, env, seen)

      _ ->
        %{"type" => "object"}
    end
  end

  defp resolve_user_type(name, env, seen) do
    cond do
      MapSet.member?(seen, name) ->
        %{"type" => "object"}

      Map.has_key?(env, name) ->
        new_seen = MapSet.put(seen, name)

        case Map.get(env, name) do
          {:type, %AST.TypeDecl{} = decl} ->
            to_json_schema(decl, env, new_seen)

          {:enum, %AST.EnumDecl{} = decl} ->
            enum_to_schema(decl, env, new_seen)

          _ ->
            %{"type" => "object"}
        end

      true ->
        %{"type" => "object"}
    end
  end

  # ------------------------------------------------------------------
  # Annotation application
  # ------------------------------------------------------------------

  defp apply_annotations(schema, annotations) do
    Enum.reduce(annotations, schema, &apply_annotation/2)
  end

  defp apply_annotation(%AST.Annotation{name: "min", value: value}, schema) do
    Map.put(schema, "minimum", extract_number(value))
  end

  defp apply_annotation(%AST.Annotation{name: "max", value: value}, schema) do
    Map.put(schema, "maximum", extract_number(value))
  end

  defp apply_annotation(%AST.Annotation{name: "one_of", value: value}, schema) do
    Map.put(schema, "enum", extract_string_list(value))
  end

  defp apply_annotation(%AST.Annotation{name: "default", value: value}, schema) do
    Map.put(schema, "default", extract_value(value))
  end

  defp apply_annotation(%AST.Annotation{name: "description", value: value}, schema) do
    Map.put(schema, "description", extract_string(value))
  end

  defp apply_annotation(_annotation, schema), do: schema

  # ------------------------------------------------------------------
  # Value extraction from AST literals
  # ------------------------------------------------------------------

  defp extract_number(%AST.IntLit{value: v}), do: v
  defp extract_number(%AST.FloatLit{value: v}), do: v
  defp extract_number(_), do: 0

  defp extract_string(%AST.StringLit{segments: [{:literal, text}]}), do: text
  defp extract_string(_), do: ""

  defp extract_string_list(%AST.ListLit{elements: elements}) do
    Enum.map(elements, &extract_string/1)
  end

  defp extract_string_list(_), do: []

  defp extract_value(%AST.IntLit{value: v}), do: v
  defp extract_value(%AST.FloatLit{value: v}), do: v
  defp extract_value(%AST.BoolLit{value: v}), do: v
  defp extract_value(%AST.StringLit{segments: [{:literal, text}]}), do: text
  defp extract_value(_), do: nil

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp is_optional?(%AST.Field{type: %AST.TypeRef{name: "Option"}}), do: true
  defp is_optional?(_), do: false
end
