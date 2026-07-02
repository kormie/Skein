defmodule Skein.Freeze.JsonSchemaFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for JSON Schema derivation.

  `docs/STABILITY.md`: for a fixed type declaration, the derived schema is
  stable within a major — same properties, same `required`, same variant
  encoding. This test derives schemas for a canonical set of declarations
  covering the derivation surface and compares them byte-for-byte (as
  JSON) against `conformance/freeze/json_schema_vectors.json`.

  A failing comparison you did not intend is a breaking change. To change
  the vectors deliberately (new construct mapping to NEW output, never
  altered output for existing declarations), run with `FREEZE_REGEN=1`
  and review the diff.
  """

  alias Skein.CodeGen.SchemaGen

  @vector Path.expand("../../../../../conformance/freeze/json_schema_vectors.json", __DIR__)

  @canonical_source """
  module FreezeSchemas {
    type Basic {
      id: Uuid @primary
      name: String
      age: Int @min(0) @max(150)
      score: Float
      active: Bool
      email: Email @unique
      homepage: Url
      joined: Instant
    }

    type WithOption {
      id: String @primary
      nickname: Option[String]
      tags: List[String]
      counts: Map[String, Int]
    }

    type Constrained {
      id: String @primary
      kind: String @one_of(["basic", "pro"])
      plan: String @default("basic")
      note: String @description("free text")
    }

    enum Color { Red Green Blue }

    enum Shape {
      Circle(radius: Int)
      Square(side: Int)
    }

    type Nested {
      id: String @primary
      owner: Basic
      color: Color
      friends: List[Basic]
    }
  }
  """

  defp derived_schemas do
    {:ok, tokens} = Skein.Lexer.tokenize(@canonical_source)
    {:ok, ast} = Skein.Parser.parse(tokens)

    declarations = ast.declarations

    env =
      Map.new(declarations, fn
        %Skein.AST.TypeDecl{name: name} = decl -> {name, {:type, decl}}
        %Skein.AST.EnumDecl{name: name} = decl -> {name, {:enum, decl}}
      end)

    Map.new(declarations, fn
      %Skein.AST.TypeDecl{name: name} = decl -> {name, SchemaGen.to_json_schema(decl, env)}
      %Skein.AST.EnumDecl{name: name} = decl -> {name, SchemaGen.enum_to_schema(decl, env)}
    end)
  end

  test "derived schemas for the canonical declarations are frozen" do
    # Round-trip through JSON so atom/string key differences can't hide.
    current = derived_schemas() |> Jason.encode!() |> Jason.decode!()

    if System.get_env("FREEZE_REGEN") == "1" do
      File.write!(
        @vector,
        Jason.encode!(%{"comment" => vector_comment(), "schemas" => current}, pretty: true) <>
          "\n"
      )

      flunk("regenerated #{@vector} — review the diff and commit it deliberately")
    else
      %{"schemas" => frozen} = @vector |> File.read!() |> Jason.decode!()

      assert current == frozen,
             "JSON Schema derivation drifted from the frozen vectors — " <>
               "for existing declarations this is a MAJOR-level break " <>
               "(docs/STABILITY.md). If the change is a deliberate new-construct " <>
               "mapping, regenerate with FREEZE_REGEN=1 and review the diff."
    end
  end

  defp vector_comment do
    "Frozen JSON Schema derivation vectors (#332): schemas derived from the " <>
      "canonical declarations in json_schema_freeze_test.exs. The schema for " <>
      "a fixed declaration only changes in a major."
  end
end
