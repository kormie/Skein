defmodule Skein.Freeze.KeywordsFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the grammar's keyword inventory.

  Reserving a new word post-1.0 is a breaking change (it steals an
  identifier from existing programs); the contextual-keyword machinery
  exists so additions stay non-breaking. This suite pins:

  - the reserved list (`Skein.Lexer.keywords/0`) against
    `conformance/freeze/keywords.json`,
  - the contextual inventory (each word must still lex as an ordinary
    identifier), and
  - both lists against the spec §2.3 code blocks, in both directions —
    editing the spec or the lexer alone fails.
  """

  @vector Path.expand("../../../../../conformance/freeze/keywords.json", __DIR__)
  @spec_path Path.expand("../../../../../docs/SKEIN_SPEC.md", __DIR__)

  defp vector, do: @vector |> File.read!() |> Jason.decode!()

  # The §2.3 code blocks: first fence = reserved words, second = contextual.
  defp spec_keyword_blocks do
    spec = File.read!(@spec_path)
    [_, section] = String.split(spec, "### 2.3 Keywords", parts: 2)
    [section, _] = String.split(section, "### 2.4", parts: 2)

    Regex.scan(~r/```\n(.*?)```/s, section, capture: :all_but_first)
    |> Enum.map(fn [block] -> block |> String.split() |> Enum.sort() end)
  end

  test "the reserved-keyword inventory matches the frozen vector" do
    assert Skein.Lexer.keywords() == vector()["reserved"],
           "the lexer's reserved keywords drifted from conformance/freeze/keywords.json — " <>
             "reserving a new word is a breaking change (prefer a contextual keyword)"
  end

  test "spec §2.3 lists exactly the frozen reserved and contextual inventories" do
    assert [spec_reserved, spec_contextual] = spec_keyword_blocks()
    assert spec_reserved == vector()["reserved"]
    assert spec_contextual == vector()["contextual"]
  end

  test "every reserved word lexes as a keyword token, never an identifier" do
    for word <- vector()["reserved"] do
      {:ok, tokens} = Skein.Lexer.tokenize(word)

      refute match?([{:ident, _, _} | _], tokens),
             "#{word} lexed as an identifier — it must stay reserved"
    end
  end

  test "every contextual keyword lexes as an ordinary identifier" do
    for word <- vector()["contextual"] ++ vector()["strategy_values"] do
      {:ok, tokens} = Skein.Lexer.tokenize(word)

      assert match?([{:ident, _, ^word} | _], tokens),
             "#{word} no longer lexes as an identifier — promoting a contextual " <>
               "keyword to reserved is a breaking change"
    end
  end

  test "a contextual keyword still works as a binding name" do
    for word <- ~w(input output state given expect) do
      source = """
      module M {
        fn f() -> Int {
          let #{word} = 1
          #{word}
        }
      }
      """

      {:ok, %{errors: errors}} = Skein.Compiler.check_string(source)
      assert errors == [], "`let #{word} = 1` stopped compiling: #{inspect(errors)}"
    end
  end
end
