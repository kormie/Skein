defmodule Skein.Lsp.SymbolsTest do
  use ExUnit.Case, async: true

  alias Skein.Lsp.Symbols

  describe "document_symbols/1 for modules" do
    test "returns module with function children" do
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

      symbols = Symbols.document_symbols(ast)

      assert length(symbols) == 1
      [mod_symbol] = symbols
      assert mod_symbol.name == "Hello"
      assert mod_symbol.kind == GenLSP.Enumerations.SymbolKind.module()
      assert length(mod_symbol.children) == 2

      [fn1, fn2] = mod_symbol.children
      assert String.contains?(fn1.name, "greet")
      assert fn1.kind == GenLSP.Enumerations.SymbolKind.function()
      assert String.contains?(fn2.name, "add")
    end

    test "returns module with handler children" do
      source = """
      module HelloHttp {
        capability http.in

        handler http GET "/health" (req) -> {
          respond.json(200, "ok")
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens, "test.skein")

      symbols = Symbols.document_symbols(ast)

      [mod_symbol] = symbols
      assert mod_symbol.name == "HelloHttp"

      handler_children =
        Enum.filter(mod_symbol.children, fn child ->
          child.kind == GenLSP.Enumerations.SymbolKind.event()
        end)

      assert length(handler_children) >= 1
    end
  end

  describe "document_symbols/1 for agents" do
    test "returns agent with phase and handler children" do
      source = """
      agent RefundAgent {
        capability model("gpt-4")
        capability memory.kv

        state {
          order_id: String
        }

        enum Phase {
          Review -> [Complete]
          Complete -> []
        }

        on start(order_id: String) -> {
          transition(Phase.Review)
        }

        on phase(Phase.Review) -> {
          transition(Phase.Complete)
        }

        on phase(Phase.Complete) -> {
          stop()
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens, "test.skein")

      symbols = Symbols.document_symbols(ast)

      assert length(symbols) == 1
      [agent_symbol] = symbols
      assert agent_symbol.name == "RefundAgent"
      assert agent_symbol.kind == GenLSP.Enumerations.SymbolKind.class()

      children = agent_symbol.children
      assert length(children) > 0

      # Should have state fields, Phase enum, and handlers
      child_kinds = Enum.map(children, & &1.kind) |> MapSet.new()
      assert GenLSP.Enumerations.SymbolKind.event() in child_kinds
    end
  end

  describe "document_symbols/1 edge cases" do
    test "returns empty list for unrecognized AST" do
      assert Symbols.document_symbols(%{}) == []
    end

    test "returns empty list for nil-like input" do
      assert Symbols.document_symbols(nil) == []
    end
  end
end
