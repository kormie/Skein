defmodule Skein.Lsp.CompletionsTest do
  use ExUnit.Case, async: true

  alias Skein.Lsp.Completions

  alias GenLSP.Structures.Position

  describe "complete/3" do
    test "provides keyword completions" do
      items = Completions.complete(nil, "fn", %Position{line: 0, character: 2})

      labels = Enum.map(items, & &1.label)
      assert "fn" in labels
    end

    test "provides type completions" do
      items = Completions.complete(nil, "St", %Position{line: 0, character: 2})

      labels = Enum.map(items, & &1.label)
      assert "String" in labels
    end

    test "annotation completions offer exactly the spec 4.2 set" do
      items = Completions.complete(nil, "@", %Position{line: 0, character: 1})

      labels = items |> Enum.map(& &1.label) |> Enum.sort()

      # Spec section 4.2 — the implemented constraint annotations. Nothing
      # unimplemented (@pattern/@optional/@deprecated) may be offered.
      assert labels ==
               Enum.sort([
                 "@min",
                 "@max",
                 "@one_of",
                 "@default",
                 "@primary",
                 "@unique",
                 "@description"
               ])
    end

    test "provides effect namespace completions" do
      items = Completions.complete(nil, "ll", %Position{line: 0, character: 2})

      labels = Enum.map(items, & &1.label)
      assert "llm" in labels
    end

    test "provides method completions after dot" do
      # "llm." — cursor is at position 4
      source = "llm."
      items = Completions.complete(nil, source, %Position{line: 0, character: 4})

      labels = Enum.map(items, & &1.label)
      assert "chat" in labels
      assert "json" in labels
      assert "stream" in labels
    end

    test "provides respond method completions" do
      source = "respond."
      items = Completions.complete(nil, source, %Position{line: 0, character: 8})

      labels = Enum.map(items, & &1.label)
      assert "json" in labels
    end

    test "provides memory method completions" do
      source = "memory."
      items = Completions.complete(nil, source, %Position{line: 0, character: 7})

      labels = Enum.map(items, & &1.label)
      assert "get" in labels
      assert "put" in labels
      assert "delete" in labels
    end

    test "provides function completions from AST" do
      source = """
      module Hello {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }

        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens, "test.skein")

      items = Completions.complete(ast, "gre", %Position{line: 5, character: 3})

      labels = Enum.map(items, & &1.label)
      assert "greet" in labels
    end

    test "provides builtin type completions" do
      items = Completions.complete(nil, "In", %Position{line: 0, character: 2})

      labels = Enum.map(items, & &1.label)
      assert "Int" in labels
      assert "Instant" in labels
    end

    test "returns completions when prefix is empty" do
      items = Completions.complete(nil, "", %Position{line: 0, character: 0})

      # Should return keywords, types, etc.
      assert length(items) > 0
    end
  end
end
