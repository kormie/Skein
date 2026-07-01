defmodule Skein.AnalyzerNominalRecordTest do
  @moduledoc """
  Nominal record soundness (#294 / B5).

  Records are nominal: a plain map literal is a `Map`, never a record, and
  `TypeName { ... }` is the one construction form. Before B5, `map ~
  user_type` was universally true, so ANY map passed as ANY record with no
  field checking — the untagged-map hole the 2026-06-19 audit flagged.
  """
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  describe "plain maps are not records" do
    test "a map literal cannot cross a record-typed return boundary" do
      errors =
        analyze_errors("""
        module M {
          type Point { x: Int, y: Int }

          fn origin() -> Point {
            { x: 0, y: 0 }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Point"
             end)
    end

    test "a map literal cannot be passed where a record is declared" do
      errors =
        analyze_errors("""
        module M {
          type Point { x: Int, y: Int }

          fn norm(p: Point) -> Int {
            p.x + p.y
          }

          fn run() -> Int {
            norm({ x: 1, y: 2 })
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Point"
             end)
    end

    test "Ok(map literal) cannot produce Result[Record, _]" do
      errors =
        analyze_errors("""
        module M {
          type Receipt { id: String }

          fn charge() -> Result[Receipt, String] {
            Ok({ id: "r-1" })
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "a record does not flow into a Map parameter" do
      errors =
        analyze_errors("""
        module M {
          type Point { x: Int, y: Int }

          fn run() -> List[String] {
            Map.keys(Point { x: 1, y: 2 })
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Map.keys"
             end)
    end
  end

  describe "nominal construction and sanctioned seams still flow" do
    test "TypeName { ... } passes at every boundary a map now fails" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type Point { x: Int, y: Int }

                 fn norm(p: Point) -> Int {
                   p.x + p.y
                 }

                 fn origin() -> Point {
                   Point { x: 0, y: 0 }
                 }

                 fn wrapped() -> Result[Point, String] {
                   Ok(Point { x: 1, y: 2 })
                 }

                 fn run() -> Int {
                   norm(Point { x: 1, y: 2 })
                 }
               }
               """)
    end

    test "the dynamic seam (untyped memory payloads) still crosses record boundaries" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("cache")

                 type Point { x: Int, y: Int }

                 fn load() -> Point {
                   memory.get!("origin")
                 }
               }
               """)
    end
  end
end
