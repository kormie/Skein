defmodule Skein.Integration.RecordLiteralTest do
  @moduledoc """
  End-to-end tests for nominal record-literal construction:
  `TypeName { field: expr, ... }`. Covers parsing, analyzer field checking,
  and codegen (the value is an atom-keyed map that field access reads back).
  """
  use ExUnit.Case, async: true

  alias Skein.{Analyzer, Compiler, Lexer, Parser, AST}

  defp parse(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Parser.parse(tokens)
  end

  defp errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast, source_text: source) do
      {:error, errs} -> errs
      {:ok, _ast} -> []
      {:ok, _ast, warnings} -> warnings
    end
  end

  describe "parsing" do
    test "parses a record literal with fields" do
      source = """
      module M {
        type Point { x: Int, y: Int }
        fn origin() -> Point { Point { x: 0, y: 0 } }
      }
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      fn_decl = Enum.find(decls, &match?(%AST.Fn{name: "origin"}, &1))
      assert %AST.Block{expressions: [body]} = fn_decl.body
      assert %AST.RecordLit{type_name: "Point", fields: [{"x", _}, {"y", _}]} = body
    end

    test "parses an empty record literal" do
      source = """
      module M {
        type Empty { }
        fn make() -> Empty { Empty { } }
      }
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      fn_decl = Enum.find(decls, &match?(%AST.Fn{name: "make"}, &1))
      assert %AST.Block{expressions: [body]} = fn_decl.body
      assert %AST.RecordLit{type_name: "Empty", fields: []} = body
    end

    test "match on an upper-ident subject still parses as a match, not a record literal" do
      # Arms are patterns (`Variant -> ...`), never `ident :`, so the
      # disambiguation keeps this a Match node.
      source = """
      module M {
        enum Color {
          Red
          Green
        }
        fn name(c: Color) -> String {
          match c {
            Red -> "red"
            Green -> "green"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      fn_decl = Enum.find(decls, &match?(%AST.Fn{name: "name"}, &1))
      assert %AST.Block{expressions: [body]} = fn_decl.body
      assert %AST.Match{} = body
    end
  end

  describe "analyzer field checking" do
    test "a well-formed record literal type-checks" do
      assert [] =
               errors("""
               module M {
                 type Point { x: Int, y: Int }
                 fn origin() -> Point { Point { x: 0, y: 0 } }
               }
               """)
    end

    test "a missing required field is a structured error" do
      errs =
        errors("""
        module M {
          type Point { x: Int, y: Int }
          fn bad() -> Point { Point { x: 0 } }
        }
        """)

      assert Enum.any?(errs, fn e ->
               e.code == "E0020" and e.message =~ "Missing required field 'y'"
             end)
    end

    test "an Option field may be omitted" do
      assert [] =
               errors("""
               module M {
                 type User { name: String, nickname: Option[String] }
                 fn make() -> User { User { name: "ada" } }
               }
               """)
    end

    test "an unknown field is a structured error" do
      errs =
        errors("""
        module M {
          type Point { x: Int, y: Int }
          fn bad() -> Point { Point { x: 0, y: 0, z: 0 } }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "Unknown field 'z'" end)
    end

    test "a field type mismatch is a structured error" do
      errs =
        errors("""
        module M {
          type Point { x: Int, y: Int }
          fn bad() -> Point { Point { x: "nope", y: 0 } }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "Field 'x'" end)
    end

    test "constructing an unknown type is a structured error" do
      errs =
        errors("""
        module M {
          fn bad() -> Nope { Nope { x: 0 } }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0024" and e.message =~ "Unknown type 'Nope'" end)
    end
  end

  describe "codegen + runtime" do
    test "a constructed record round-trips through field access" do
      mod =
        case Compiler.compile_string("""
             module M {
               type Point { x: Int, y: Int }
               fn make(a: Int, b: Int) -> Point { Point { x: a, y: b } }
               fn sum(a: Int, b: Int) -> Int {
                 let p = Point { x: a, y: b }
                 p.x + p.y
               }
             }
             """) do
          {:module, mod} -> mod
          {:error, errs} -> flunk("compile failed: #{inspect(errs)}")
        end

      assert mod.make(3, 4) == %{x: 3, y: 4}
      assert mod.sum(3, 4) == 7
    end
  end
end
