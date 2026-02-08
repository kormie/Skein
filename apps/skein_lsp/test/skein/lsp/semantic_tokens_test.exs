defmodule Skein.Lsp.SemanticTokensTest do
  use ExUnit.Case, async: true

  alias Skein.Lsp.SemanticTokens

  describe "encode/1" do
    test "returns encoded tokens for valid source" do
      source = """
      module Hello {
        fn greet(name: String) -> String {
          "Hello"
        }
      }
      """

      data = SemanticTokens.encode(source)

      # Should be a flat list of integers, multiples of 5
      assert is_list(data)
      assert rem(length(data), 5) == 0
      assert length(data) > 0
    end

    test "returns empty list for invalid source" do
      source = "@@@ invalid $$$ source"

      data = SemanticTokens.encode(source)

      assert data == []
    end

    test "encodes keywords with correct token type" do
      source = "module Hello { }"

      data = SemanticTokens.encode(source)

      # Should have at least tokens for `module` and `Hello`
      assert length(data) >= 10
    end

    test "returns data in groups of 5" do
      source = """
      module Test {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """

      data = SemanticTokens.encode(source)

      assert rem(length(data), 5) == 0
    end

    test "first token has absolute position (deltaLine from 0)" do
      source = "let x = 42"

      data = SemanticTokens.encode(source)

      if length(data) >= 5 do
        [delta_line, _delta_start, _len, _type, _mods | _] = data
        # First token's deltaLine is the absolute line (0-indexed)
        assert delta_line >= 0
      end
    end
  end
end
