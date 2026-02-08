defmodule Skein.CodeGen.SchemaGenTest do
  use ExUnit.Case, async: true

  alias Skein.AST
  alias Skein.CodeGen.SchemaGen

  # Helper: build a TypeRef
  defp type_ref(name, params \\ []) do
    %AST.TypeRef{name: name, params: params, meta: %{line: 1, col: 1, file: "test"}}
  end

  # Helper: build a Field
  defp field(name, type, annotations \\ []) do
    %AST.Field{
      name: name,
      type: type,
      annotations: annotations,
      meta: %{line: 1, col: 1, file: "test"}
    }
  end

  # Helper: build an Annotation
  defp annotation(name, value \\ nil) do
    %AST.Annotation{name: name, value: value, meta: %{line: 1, col: 1, file: "test"}}
  end

  # ------------------------------------------------------------------
  # Built-in type schemas
  # ------------------------------------------------------------------

  describe "built-in type schemas" do
    test "Int -> integer" do
      assert SchemaGen.type_to_schema(type_ref("Int")) == %{"type" => "integer"}
    end

    test "Float -> number" do
      assert SchemaGen.type_to_schema(type_ref("Float")) == %{"type" => "number"}
    end

    test "String -> string" do
      assert SchemaGen.type_to_schema(type_ref("String")) == %{"type" => "string"}
    end

    test "Bool -> boolean" do
      assert SchemaGen.type_to_schema(type_ref("Bool")) == %{"type" => "boolean"}
    end

    test "Uuid -> string with uuid format" do
      assert SchemaGen.type_to_schema(type_ref("Uuid")) == %{
               "type" => "string",
               "format" => "uuid"
             }
    end

    test "Instant -> string with date-time format" do
      assert SchemaGen.type_to_schema(type_ref("Instant")) == %{
               "type" => "string",
               "format" => "date-time"
             }
    end

    test "Duration -> string" do
      assert SchemaGen.type_to_schema(type_ref("Duration")) == %{"type" => "string"}
    end

    test "Email -> string with email format" do
      assert SchemaGen.type_to_schema(type_ref("Email")) == %{
               "type" => "string",
               "format" => "email"
             }
    end

    test "Url -> string with uri format" do
      assert SchemaGen.type_to_schema(type_ref("Url")) == %{
               "type" => "string",
               "format" => "uri"
             }
    end
  end

  # ------------------------------------------------------------------
  # Parameterized type schemas
  # ------------------------------------------------------------------

  describe "parameterized type schemas" do
    test "List[String] -> array of strings" do
      assert SchemaGen.type_to_schema(type_ref("List", [type_ref("String")])) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "List[Int] -> array of integers" do
      assert SchemaGen.type_to_schema(type_ref("List", [type_ref("Int")])) == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }
    end

    test "Set[String] -> array with uniqueItems" do
      assert SchemaGen.type_to_schema(type_ref("Set", [type_ref("String")])) == %{
               "type" => "array",
               "uniqueItems" => true,
               "items" => %{"type" => "string"}
             }
    end

    test "Map[String, Int] -> object" do
      assert SchemaGen.type_to_schema(type_ref("Map", [type_ref("String"), type_ref("Int")])) ==
               %{"type" => "object"}
    end

    test "Option[String] -> string schema (required handled elsewhere)" do
      assert SchemaGen.type_to_schema(type_ref("Option", [type_ref("String")])) == %{
               "type" => "string"
             }
    end
  end

  # ------------------------------------------------------------------
  # Type declaration -> JSON Schema
  # ------------------------------------------------------------------

  describe "to_json_schema/1 - type declarations" do
    test "simple type generates object schema" do
      type_decl = %AST.TypeDecl{
        name: "User",
        fields: [
          field("name", type_ref("String")),
          field("age", type_ref("Int"))
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)

      assert schema == %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"}
               },
               "required" => ["age", "name"]
             }
    end

    test "type with Option field excludes it from required" do
      type_decl = %AST.TypeDecl{
        name: "CreateUser",
        fields: [
          field("email", type_ref("Email")),
          field("name", type_ref("String")),
          field("phone", type_ref("Option", [type_ref("String")]))
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)

      assert schema["type"] == "object"
      assert schema["properties"]["email"] == %{"type" => "string", "format" => "email"}
      assert schema["properties"]["name"] == %{"type" => "string"}
      assert schema["properties"]["phone"] == %{"type" => "string"}
      # phone is NOT in required
      assert "email" in schema["required"]
      assert "name" in schema["required"]
      refute "phone" in schema["required"]
    end

    test "type with Uuid field" do
      type_decl = %AST.TypeDecl{
        name: "Item",
        fields: [
          field("id", type_ref("Uuid")),
          field("name", type_ref("String"))
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)
      assert schema["properties"]["id"] == %{"type" => "string", "format" => "uuid"}
    end
  end

  # ------------------------------------------------------------------
  # Constraint annotations in schema
  # ------------------------------------------------------------------

  describe "constraint annotations" do
    test "@min adds minimum to schema" do
      type_decl = %AST.TypeDecl{
        name: "Money",
        fields: [
          field("amount", type_ref("Int"), [annotation("min", %AST.IntLit{value: 0, meta: %{}})])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)
      assert schema["properties"]["amount"] == %{"type" => "integer", "minimum" => 0}
    end

    test "@max adds maximum to schema" do
      type_decl = %AST.TypeDecl{
        name: "Score",
        fields: [
          field("value", type_ref("Int"), [annotation("max", %AST.IntLit{value: 100, meta: %{}})])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)
      assert schema["properties"]["value"] == %{"type" => "integer", "maximum" => 100}
    end

    test "@min and @max together" do
      type_decl = %AST.TypeDecl{
        name: "Bounded",
        fields: [
          field("value", type_ref("Int"), [
            annotation("min", %AST.IntLit{value: 0, meta: %{}}),
            annotation("max", %AST.IntLit{value: 100, meta: %{}})
          ])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)

      assert schema["properties"]["value"] == %{
               "type" => "integer",
               "minimum" => 0,
               "maximum" => 100
             }
    end

    test "@one_of adds enum to schema" do
      type_decl = %AST.TypeDecl{
        name: "Currency",
        fields: [
          field("code", type_ref("String"), [
            annotation("one_of", %AST.ListLit{
              elements: [
                %AST.StringLit{segments: [{:literal, "USD"}], meta: %{}},
                %AST.StringLit{segments: [{:literal, "EUR"}], meta: %{}},
                %AST.StringLit{segments: [{:literal, "GBP"}], meta: %{}}
              ],
              meta: %{}
            })
          ])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)

      assert schema["properties"]["code"] == %{
               "type" => "string",
               "enum" => ["USD", "EUR", "GBP"]
             }
    end

    test "@default adds default to schema" do
      type_decl = %AST.TypeDecl{
        name: "Config",
        fields: [
          field("status", type_ref("String"), [
            annotation("default", %AST.StringLit{segments: [{:literal, "pending"}], meta: %{}})
          ])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)
      assert schema["properties"]["status"] == %{"type" => "string", "default" => "pending"}
    end

    test "@description adds description to schema" do
      type_decl = %AST.TypeDecl{
        name: "Tool",
        fields: [
          field("customer_id", type_ref("String"), [
            annotation("description", %AST.StringLit{
              segments: [{:literal, "Stripe customer ID"}],
              meta: %{}
            })
          ])
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.to_json_schema(type_decl)

      assert schema["properties"]["customer_id"] == %{
               "type" => "string",
               "description" => "Stripe customer ID"
             }
    end
  end

  # ------------------------------------------------------------------
  # Enum -> JSON Schema
  # ------------------------------------------------------------------

  describe "enum_to_schema/1" do
    test "simple enum generates string enum schema" do
      enum_decl = %AST.EnumDecl{
        name: "Status",
        variants: [
          %AST.Variant{name: "Pending", fields: [], transitions: [], meta: %{}},
          %AST.Variant{name: "Active", fields: [], transitions: [], meta: %{}},
          %AST.Variant{name: "Completed", fields: [], transitions: [], meta: %{}}
        ],
        transitions: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      schema = SchemaGen.enum_to_schema(enum_decl)

      assert schema == %{
               "type" => "string",
               "enum" => ["Active", "Completed", "Pending"]
             }
    end
  end

  # ------------------------------------------------------------------
  # JSON output
  # ------------------------------------------------------------------

  describe "to_json/1" do
    test "produces valid JSON string" do
      type_decl = %AST.TypeDecl{
        name: "User",
        fields: [
          field("name", type_ref("String")),
          field("age", type_ref("Int"))
        ],
        constraints: [],
        meta: %{line: 1, col: 1, file: "test"}
      }

      json = SchemaGen.to_json(type_decl)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["type"] == "object"
      assert Map.has_key?(decoded, "properties")
    end
  end
end
