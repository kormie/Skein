defmodule Skein.Integration.ProviderContractTypesTest do
  @moduledoc """
  Effect provider contract types (#274): HttpRequest/HttpResponse/LlmRequest/
  LlmResponse and the `Json` type. These are the named, schema-deriving types a
  scenario `implement` block references. Modeled as built-in TypeDecls so they
  can be used in signatures, constructed with record literals, field-accessed,
  and derived to JSON Schema.
  """
  use ExUnit.Case, async: true

  alias Skein.{Analyzer, Lexer, Parser, AST}
  alias Skein.CodeGen.SchemaGen

  defp errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast, source_text: source) do
      {:error, errs} -> errs
      {:ok, _ast} -> []
      {:ok, _ast, warnings} -> warnings
    end
  end

  describe "contract types are usable in signatures and construction" do
    test "HttpRequest/HttpResponse fields type-check; Json body accepts any value" do
      assert [] =
               errors("""
               module M {
                 fn respond(req: HttpRequest) -> HttpResponse {
                   match req.method {
                     "GET" -> HttpResponse { status: 200, body: { ok: true }, headers: {} }
                     _ -> HttpResponse { status: 405, body: { ok: false }, headers: {} }
                   }
                 }
               }
               """)
    end

    test "LlmRequest/LlmResponse construct and field-access" do
      assert [] =
               errors("""
               module M {
                 fn answer(req: LlmRequest) -> LlmResponse {
                   let p = req.prompt
                   LlmResponse { text: p }
                 }
               }
               """)
    end

    test "Json field accepts an object, array-ish, or scalar via Map.get-free assignment" do
      assert [] =
               errors("""
               module M {
                 fn make(s: String) -> HttpRequest {
                   HttpRequest { method: "POST", url: "https://x", headers: {}, body: { a: 1 } }
                 }
               }
               """)
    end

    test "a wrong field type in a contract record is a structured error" do
      errs =
        errors("""
        module M {
          fn bad() -> HttpResponse {
            HttpResponse { status: "two hundred", body: {}, headers: {} }
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "status" end)
    end

    test "a missing required field in a contract record is a structured error" do
      errs =
        errors("""
        module M {
          fn bad() -> LlmResponse { LlmResponse { } }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "text" end)
    end
  end

  describe "schema derivation" do
    test "Json derives to the permissive (any) schema" do
      assert %{} == SchemaGen.type_to_schema(%AST.TypeRef{name: "Json", params: [], meta: %{}})
    end

    test "an HttpRequest-shaped field list derives a JSON object schema" do
      fields = [
        %AST.Field{
          name: "method",
          type: %AST.TypeRef{name: "String", params: [], meta: %{}},
          annotations: [],
          meta: %{}
        },
        %AST.Field{
          name: "body",
          type: %AST.TypeRef{name: "Json", params: [], meta: %{}},
          annotations: [],
          meta: %{}
        }
      ]

      schema = SchemaGen.fields_to_schema(fields)
      assert schema["type"] == "object"
      assert schema["properties"]["method"] == %{"type" => "string"}
      assert schema["properties"]["body"] == %{}
      assert "method" in schema["required"]
      assert "body" in schema["required"]
    end
  end
end
