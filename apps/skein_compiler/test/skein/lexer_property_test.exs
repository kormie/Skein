defmodule Skein.LexerPropertyTest do
  @moduledoc """
  Property-based tests for the Skein lexer.

  Uses StreamData generators to verify invariants across large input spaces.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Lexer

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  @keywords ~w(
    module fn let match type enum handler agent tool capability
    supervisor test scenario golden on emit transition stop suspend
    resume true false implement input output errors policy description
    state strategy child replay given expect assert
  )

  defp lower_ident_gen do
    gen all(
          first <- StreamData.member_of(Enum.to_list(?a..?z)),
          rest <-
            StreamData.list_of(
              StreamData.member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_]),
              min_length: 0,
              max_length: 20
            )
        ) do
      name = List.to_string([first | rest])
      # Ensure we don't accidentally generate a keyword
      if name in @keywords, do: "z" <> name, else: name
    end
  end

  defp upper_ident_gen do
    gen all(
          first <- StreamData.member_of(Enum.to_list(?A..?Z)),
          rest <-
            StreamData.list_of(
              StreamData.member_of(
                Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9)
              ),
              min_length: 0,
              max_length: 20
            )
        ) do
      List.to_string([first | rest])
    end
  end

  defp positive_int_gen do
    StreamData.positive_integer()
  end

  defp simple_string_content_gen do
    # Generate string content without special chars that need escaping
    StreamData.string(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ [?\s, ?0, ?1, ?2],
      min_length: 0,
      max_length: 30
    )
  end

  # ------------------------------------------------------------------
  # Lexer Properties
  # ------------------------------------------------------------------

  property "tokenizing any valid lower identifier produces an :ident token" do
    check all(name <- lower_ident_gen()) do
      assert {:ok, [{:ident, {1, 1}, ^name}, {:eof, _}]} = Lexer.tokenize(name)
    end
  end

  property "tokenizing any valid upper identifier produces an :upper_ident token" do
    check all(name <- upper_ident_gen()) do
      assert {:ok, [{:upper_ident, {1, 1}, ^name}, {:eof, _}]} = Lexer.tokenize(name)
    end
  end

  property "tokenizing any positive integer produces an :int token with that value" do
    check all(n <- positive_int_gen()) do
      source = Integer.to_string(n)
      assert {:ok, [{:int, {1, 1}, ^n}, {:eof, _}]} = Lexer.tokenize(source)
    end
  end

  property "tokenizing a quoted string produces a :string token" do
    check all(content <- simple_string_content_gen()) do
      source = "\"#{content}\""
      assert {:ok, [{:string, {1, 1}, _segments}, {:eof, _}]} = Lexer.tokenize(source)
    end
  end

  property "simple string round-trip: literal content is preserved" do
    check all(content <- simple_string_content_gen()) do
      source = "\"#{content}\""
      assert {:ok, [{:string, {1, 1}, segments}, {:eof, _}]} = Lexer.tokenize(source)

      recovered =
        case segments do
          [] -> ""
          [{:literal, text}] -> text
          _ -> Enum.map_join(segments, "", fn {:literal, t} -> t end)
        end

      assert recovered == content
    end
  end

  property "tokenizing always ends with :eof" do
    check all(
            source <-
              StreamData.one_of([
                lower_ident_gen(),
                upper_ident_gen(),
                StreamData.map(positive_int_gen(), &Integer.to_string/1),
                StreamData.constant("")
              ])
          ) do
      assert {:ok, tokens} = Lexer.tokenize(source)
      assert {:eof, _} = List.last(tokens)
    end
  end

  property "token positions are always positive (line >= 1, col >= 1)" do
    check all(
            source <-
              StreamData.one_of([
                lower_ident_gen(),
                upper_ident_gen(),
                StreamData.map(positive_int_gen(), &Integer.to_string/1)
              ])
          ) do
      assert {:ok, tokens} = Lexer.tokenize(source)

      for token <- tokens do
        {ln, cl} =
          case token do
            {_, {line, col}} -> {line, col}
            {_, {line, col}, _} -> {line, col}
          end

        assert ln >= 1, "line should be >= 1, got #{ln}"
        assert cl >= 1, "col should be >= 1, got #{cl}"
      end
    end
  end

  property "all keywords tokenize to their corresponding atom" do
    check all(kw <- StreamData.member_of(@keywords)) do
      atom = String.to_atom(kw)
      assert {:ok, [{^atom, {1, 1}}, {:eof, _}]} = Lexer.tokenize(kw)
    end
  end

  property "whitespace-separated identifiers produce correct token count" do
    check all(names <- StreamData.list_of(lower_ident_gen(), min_length: 1, max_length: 5)) do
      source = Enum.join(names, " ")
      assert {:ok, tokens} = Lexer.tokenize(source)
      # tokens = N idents + 1 eof
      assert length(tokens) == length(names) + 1
    end
  end

  property "newlines increment line numbers" do
    check all(n <- StreamData.integer(1..5)) do
      lines = String.duplicate("\n", n)
      source = lines <> "x"
      assert {:ok, [{:ident, {line, 1}, "x"}, {:eof, _}]} = Lexer.tokenize(source)
      assert line == n + 1
    end
  end

  property "string interpolation with valid identifier preserves the identifier name" do
    check all(name <- lower_ident_gen()) do
      source = "\"${#{name}}\""
      assert {:ok, [{:string, {1, 1}, segments}, {:eof, _}]} = Lexer.tokenize(source)

      interp_names =
        for {:interpolation, {:ident, _, n}} <- segments, do: n

      assert interp_names == [name]
    end
  end
end
