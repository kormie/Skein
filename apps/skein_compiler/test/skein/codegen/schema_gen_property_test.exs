defmodule Skein.CodeGen.SchemaGenPropertyTest do
  @moduledoc """
  Property tests for JSON Schema generation.

  Core invariant (CLAUDE.md design constraint #3): every named type must be
  derivable to JSON Schema. These properties generate arbitrary type shapes
  and assert the derived schemas are well-formed and JSON-serializable.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.AST
  alias Skein.CodeGen.SchemaGen

  @meta %{line: 1, col: 1, file: "property_test"}

  @base_types ~w(Int Float String Bool Uuid Instant Duration Email Url)

  defp type_ref(name, params \\ []), do: %AST.TypeRef{name: name, params: params, meta: @meta}

  defp base_type_gen do
    StreamData.member_of(@base_types) |> StreamData.map(&type_ref/1)
  end

  # Recursively nested types: List[T], Set[T], Option[T], Map[String, T]
  defp type_gen do
    StreamData.tree(base_type_gen(), fn child ->
      StreamData.one_of([
        StreamData.map(child, &type_ref("List", [&1])),
        StreamData.map(child, &type_ref("Set", [&1])),
        StreamData.map(child, &type_ref("Option", [&1])),
        StreamData.map(child, &type_ref("Map", [type_ref("String"), &1]))
      ])
    end)
  end

  # Identifier-ish field names, prefixed to avoid keyword collisions
  defp field_name_gen do
    StreamData.string([?a..?z, ?0..?9, ?_], min_length: 1, max_length: 12)
    |> StreamData.map(&("z" <> &1))
  end

  defp field_gen do
    StreamData.bind(field_name_gen(), fn name ->
      StreamData.map(type_gen(), fn type ->
        %AST.Field{name: name, type: type, annotations: [], meta: @meta}
      end)
    end)
  end

  defp fields_gen do
    StreamData.uniq_list_of(field_gen(), uniq_fun: & &1.name, min_length: 0, max_length: 8)
  end

  property "every generated type derives a JSON-serializable schema" do
    check all(type <- type_gen()) do
      schema = SchemaGen.type_to_schema(type)
      assert is_map(schema)
      assert is_binary(Jason.encode!(schema))
    end
  end

  property "every type schema declares a JSON type" do
    check all(type <- type_gen()) do
      schema = SchemaGen.type_to_schema(type)
      assert Map.has_key?(schema, "type") or Map.has_key?(schema, "oneOf")
    end
  end

  property "fields_to_schema covers every field as a property" do
    check all(fields <- fields_gen()) do
      schema = SchemaGen.fields_to_schema(fields)

      assert schema["type"] == "object"

      assert Map.keys(schema["properties"]) |> Enum.sort() ==
               Enum.map(fields, & &1.name) |> Enum.sort()

      assert is_binary(Jason.encode!(schema))
    end
  end

  property "Option fields are omitted from required, all others are present" do
    check all(fields <- fields_gen()) do
      schema = SchemaGen.fields_to_schema(fields)

      expected_required =
        fields
        |> Enum.reject(fn f -> f.type.name == "Option" end)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert schema["required"] == expected_required
    end
  end

  property "List and Set schemas carry the element schema as items" do
    check all(
            inner <- type_gen(),
            container <- StreamData.member_of(["List", "Set"])
          ) do
      schema = SchemaGen.type_to_schema(type_ref(container, [inner]))

      assert schema["type"] == "array"
      assert schema["items"] == SchemaGen.type_to_schema(inner)
    end
  end

  property "Option is transparent: schema matches the inner type's schema" do
    check all(inner <- type_gen()) do
      assert SchemaGen.type_to_schema(type_ref("Option", [inner])) ==
               SchemaGen.type_to_schema(inner)
    end
  end

  property "value-only enums derive a sorted string enum schema" do
    check all(
            names <-
              StreamData.uniq_list_of(
                StreamData.string([?A..?Z, ?a..?z], min_length: 1, max_length: 10)
                |> StreamData.map(&String.capitalize/1),
                min_length: 1,
                max_length: 6
              )
          ) do
      variants =
        Enum.map(names, &%AST.Variant{name: &1, fields: [], transitions: [], meta: @meta})

      enum_decl = %AST.EnumDecl{name: "ZEnum", variants: variants, meta: @meta}

      schema = SchemaGen.enum_to_schema(enum_decl)
      assert schema["type"] == "string"
      assert schema["enum"] == Enum.sort(names)
      assert is_binary(Jason.encode!(schema))
    end
  end
end
