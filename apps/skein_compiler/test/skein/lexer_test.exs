defmodule Skein.LexerTest do
  use ExUnit.Case, async: true

  alias Skein.Lexer

  describe "tokenize/1 - keywords" do
    test "tokenizes all keywords" do
      keywords = ~w(
        module fn let match type enum handler agent tool capability
        supervisor test scenario golden on emit transition stop suspend
        resume true false implement idempotent
      )

      for kw <- keywords do
        assert {:ok, [{atom, {1, 1}}, {:eof, _}]} = Lexer.tokenize(kw)
        assert atom == String.to_atom(kw), "Expected keyword #{kw} to produce atom :#{kw}"
      end
    end

    test "contextual keywords tokenize as identifiers" do
      contextual = ~w(input output errors policy description state strategy child replay given expect assert)

      for kw <- contextual do
        assert {:ok, [{:ident, {1, 1}, ^kw}, {:eof, _}]} = Lexer.tokenize(kw)
      end
    end
  end

  describe "tokenize/1 - identifiers" do
    test "tokenizes a simple lower identifier" do
      assert {:ok, [{:ident, {1, 1}, "hello"}, {:eof, _}]} = Lexer.tokenize("hello")
    end

    test "tokenizes lower identifier with underscores" do
      assert {:ok, [{:ident, {1, 1}, "my_var_name"}, {:eof, _}]} = Lexer.tokenize("my_var_name")
    end

    test "tokenizes lower identifier with digits" do
      assert {:ok, [{:ident, {1, 1}, "var1"}, {:eof, _}]} = Lexer.tokenize("var1")
    end

    test "tokenizes underscore-prefixed identifier" do
      assert {:ok, [{:ident, {1, 1}, "_unused"}, {:eof, _}]} = Lexer.tokenize("_unused")
    end

    test "tokenizes upper identifier" do
      assert {:ok, [{:upper_ident, {1, 1}, "Hello"}, {:eof, _}]} = Lexer.tokenize("Hello")
    end

    test "tokenizes upper identifier with digits" do
      assert {:ok, [{:upper_ident, {1, 1}, "Phase2"}, {:eof, _}]} = Lexer.tokenize("Phase2")
    end

    test "tokenizes multiple upper case in identifier" do
      assert {:ok, [{:upper_ident, {1, 1}, "HTTPServer"}, {:eof, _}]} =
               Lexer.tokenize("HTTPServer")
    end
  end

  describe "tokenize/1 - integer literals" do
    test "tokenizes simple integer" do
      assert {:ok, [{:int, {1, 1}, 42}, {:eof, _}]} = Lexer.tokenize("42")
    end

    test "tokenizes zero" do
      assert {:ok, [{:int, {1, 1}, 0}, {:eof, _}]} = Lexer.tokenize("0")
    end

    test "tokenizes integer with underscores" do
      assert {:ok, [{:int, {1, 1}, 1_000_000}, {:eof, _}]} = Lexer.tokenize("1_000_000")
    end

    test "tokenizes large integer" do
      assert {:ok, [{:int, {1, 1}, 9999}, {:eof, _}]} = Lexer.tokenize("9999")
    end
  end

  describe "tokenize/1 - float literals" do
    test "tokenizes simple float" do
      assert {:ok, [{:float, {1, 1}, 3.14}, {:eof, _}]} = Lexer.tokenize("3.14")
    end

    test "tokenizes float with leading zero" do
      assert {:ok, [{:float, {1, 1}, 0.5}, {:eof, _}]} = Lexer.tokenize("0.5")
    end
  end

  describe "tokenize/1 - string literals" do
    test "tokenizes simple string" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "hello"}]}, {:eof, _}]} =
               Lexer.tokenize(~s("hello"))
    end

    test "tokenizes empty string" do
      assert {:ok, [{:string, {1, 1}, []}, {:eof, _}]} = Lexer.tokenize(~s(""))
    end

    test "tokenizes string with escape sequences" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "hello\nworld"}]}, {:eof, _}]} =
               Lexer.tokenize(~s("hello\\nworld"))
    end

    test "tokenizes string with tab escape" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "a\tb"}]}, {:eof, _}]} =
               Lexer.tokenize(~s("a\\tb"))
    end

    test "tokenizes string with escaped quote" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "say \"hi\""}]}, {:eof, _}]} =
               Lexer.tokenize(~s("say \\"hi\\""))
    end

    test "tokenizes string with escaped backslash" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "path\\here"}]}, {:eof, _}]} =
               Lexer.tokenize(~s("path\\\\here"))
    end

    test "tokenizes string with interpolation" do
      assert {:ok, tokens} = Lexer.tokenize(~s("Hello, ${name}!"))

      assert [{:string, {1, 1}, segments}, {:eof, _}] = tokens

      assert [
               {:literal, "Hello, "},
               {:interpolation, {:ident, {1, 11}, "name"}},
               {:literal, "!"}
             ] = segments
    end

    test "tokenizes string with multiple interpolations" do
      assert {:ok, [{:string, {1, 1}, segments}, {:eof, _}]} =
               Lexer.tokenize(~s("${a} and ${b}"))

      assert [
               {:interpolation, {:ident, {1, 4}, "a"}},
               {:literal, " and "},
               {:interpolation, {:ident, {1, 13}, "b"}}
             ] = segments
    end

    test "tokenizes string with dot access in interpolation" do
      assert {:ok, [{:string, {1, 1}, segments}, {:eof, _}]} =
               Lexer.tokenize(~s("id: ${req.params.id}"))

      assert [
               {:literal, "id: "},
               {:interpolation,
                {:field_access, {:field_access, {:ident, {1, 8}, "req"}, "params"}, "id"}}
             ] = segments
    end

    test "reports error on unterminated string" do
      assert {:error, [error]} = Lexer.tokenize(~s("unterminated))
      assert error.code == "E0002"
      assert error.message =~ "Unterminated string"
    end

    test "tokenizes string with escaped dollar sign" do
      assert {:ok, [{:string, {1, 1}, [{:literal, "$100"}]}, {:eof, _}]} =
               Lexer.tokenize(~s("\\$100"))
    end
  end

  describe "tokenize/1 - operators" do
    test "tokenizes assignment operator" do
      assert {:ok, [{:eq, {1, 1}}, {:eof, _}]} = Lexer.tokenize("=")
    end

    test "tokenizes arrow operator" do
      assert {:ok, [{:arrow, {1, 1}}, {:eof, _}]} = Lexer.tokenize("->")
    end

    test "tokenizes pipe operator" do
      assert {:ok, [{:pipe, {1, 1}}, {:eof, _}]} = Lexer.tokenize("|>")
    end

    test "tokenizes bang operator" do
      assert {:ok, [{:bang, {1, 1}}, {:eof, _}]} = Lexer.tokenize("!")
    end

    test "tokenizes question operator" do
      assert {:ok, [{:question, {1, 1}}, {:eof, _}]} = Lexer.tokenize("?")
    end

    test "tokenizes dot operator" do
      assert {:ok, [{:dot, {1, 1}}, {:eof, _}]} = Lexer.tokenize(".")
    end

    test "tokenizes colon" do
      assert {:ok, [{:colon, {1, 1}}, {:eof, _}]} = Lexer.tokenize(":")
    end

    test "tokenizes comma" do
      assert {:ok, [{:comma, {1, 1}}, {:eof, _}]} = Lexer.tokenize(",")
    end

    test "tokenizes at sign" do
      assert {:ok, [{:at, {1, 1}}, {:eof, _}]} = Lexer.tokenize("@")
    end

    test "tokenizes ampersand" do
      assert {:ok, [{:ampersand, {1, 1}}, {:eof, _}]} = Lexer.tokenize("&")
    end

    test "tokenizes arithmetic operators" do
      assert {:ok, tokens} = Lexer.tokenize("+ - * /")
      types = Enum.map(tokens, &elem(&1, 0))
      assert :plus in types
      assert :minus in types
      assert :star in types
      assert :slash in types
    end

    test "tokenizes comparison operators" do
      assert {:ok, tokens} = Lexer.tokenize("== != < > <= >=")
      types = Enum.map(tokens, &elem(&1, 0))
      assert :eq_eq in types
      assert :neq in types
      assert :lt in types
      assert :gt in types
      assert :lte in types
      assert :gte in types
    end

    test "tokenizes logical operators" do
      assert {:ok, tokens} = Lexer.tokenize("&& ||")
      types = Enum.map(tokens, &elem(&1, 0))
      assert :and_and in types
      assert :or_or in types
    end

    test "tokenizes all operators in a line" do
      assert {:ok, tokens} = Lexer.tokenize("= -> |> ! ? . : , @ &")
      types = Enum.map(tokens, &elem(&1, 0))
      assert :eq in types
      assert :arrow in types
      assert :pipe in types
      assert :bang in types
      assert :question in types
      assert :dot in types
      assert :colon in types
      assert :comma in types
      assert :at in types
      assert :ampersand in types
    end
  end

  describe "tokenize/1 - delimiters" do
    test "tokenizes braces" do
      assert {:ok, [{:lbrace, {1, 1}}, {:rbrace, {1, 3}}, {:eof, _}]} = Lexer.tokenize("{ }")
    end

    test "tokenizes parentheses" do
      assert {:ok, [{:lparen, {1, 1}}, {:rparen, {1, 2}}, {:eof, _}]} = Lexer.tokenize("()")
    end

    test "tokenizes brackets" do
      assert {:ok, [{:lbracket, {1, 1}}, {:rbracket, {1, 2}}, {:eof, _}]} = Lexer.tokenize("[]")
    end
  end

  describe "tokenize/1 - comments" do
    test "skips line comments" do
      assert {:ok, tokens} = Lexer.tokenize("let x = 42 -- this is a comment")

      token_types = Enum.map(tokens, &elem(&1, 0))
      refute :comment in token_types

      assert [{:let, _}, {:ident, _, "x"}, {:eq, _}, {:int, _, 42}, {:eof, _}] = tokens
    end

    test "handles comment at start of line" do
      assert {:ok, [{:eof, _}]} = Lexer.tokenize("-- just a comment")
    end

    test "handles comment followed by code on next line" do
      source = "-- comment\nlet x = 1"
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [{:let, {2, 1}}, {:ident, {2, 5}, "x"}, {:eq, {2, 7}}, {:int, {2, 9}, 1}, {:eof, _}] =
               tokens
    end
  end

  describe "tokenize/1 - whitespace and position tracking" do
    test "tracks column positions correctly" do
      assert {:ok, tokens} = Lexer.tokenize("let x = 42")

      assert tokens == [
               {:let, {1, 1}},
               {:ident, {1, 5}, "x"},
               {:eq, {1, 7}},
               {:int, {1, 9}, 42},
               {:eof, {1, 11}}
             ]
    end

    test "tracks line numbers across newlines" do
      source = "let x = 1\nlet y = 2"
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:let, {1, 1}},
               {:ident, {1, 5}, "x"},
               {:eq, {1, 7}},
               {:int, {1, 9}, 1},
               {:let, {2, 1}},
               {:ident, {2, 5}, "y"},
               {:eq, {2, 7}},
               {:int, {2, 9}, 2},
               {:eof, _}
             ] = tokens
    end

    test "handles empty input" do
      assert {:ok, [{:eof, {1, 1}}]} = Lexer.tokenize("")
    end

    test "handles only whitespace" do
      assert {:ok, [{:eof, {1, 4}}]} = Lexer.tokenize("   ")
    end

    test "handles tabs" do
      assert {:ok, [{:ident, {1, 2}, "x"}, {:eof, _}]} = Lexer.tokenize("\tx")
    end
  end

  describe "tokenize/1 - composite expressions" do
    test "tokenizes a simple let binding" do
      assert {:ok, tokens} = Lexer.tokenize("let x = 42")

      assert tokens == [
               {:let, {1, 1}},
               {:ident, {1, 5}, "x"},
               {:eq, {1, 7}},
               {:int, {1, 9}, 42},
               {:eof, {1, 11}}
             ]
    end

    test "tokenizes a module declaration" do
      assert {:ok, tokens} = Lexer.tokenize("module Hello { }")

      assert tokens == [
               {:module, {1, 1}},
               {:upper_ident, {1, 8}, "Hello"},
               {:lbrace, {1, 14}},
               {:rbrace, {1, 16}},
               {:eof, {1, 17}}
             ]
    end

    test "tokenizes function declaration header" do
      source = "fn greet(name: String) -> String"
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:fn, {1, 1}},
               {:ident, {1, 4}, "greet"},
               {:lparen, {1, 9}},
               {:ident, {1, 10}, "name"},
               {:colon, {1, 14}},
               {:upper_ident, {1, 16}, "String"},
               {:rparen, {1, 22}},
               {:arrow, {1, 24}},
               {:upper_ident, {1, 27}, "String"},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes pipe expression" do
      source = "data |> String.trim() |> String.upcase()"
      assert {:ok, tokens} = Lexer.tokenize(source)

      token_types = Enum.map(tokens, &elem(&1, 0))
      assert :pipe in token_types
    end

    test "tokenizes match expression" do
      source = """
      match n > 0 {
        true  -> "positive"
        false -> "non-positive"
      }
      """

      assert {:ok, tokens} = Lexer.tokenize(source)
      token_types = Enum.map(tokens, &elem(&1, 0))

      assert :match in token_types
      assert :gt in token_types
      assert true in token_types
      assert false in token_types
      assert :arrow in token_types
    end

    test "tokenizes binary operation" do
      assert {:ok, tokens} = Lexer.tokenize("a + b * c")

      assert [
               {:ident, {1, 1}, "a"},
               {:plus, {1, 3}},
               {:ident, {1, 5}, "b"},
               {:star, {1, 7}},
               {:ident, {1, 9}, "c"},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes type annotation" do
      source = "amount: Int @min(0)"
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:ident, {1, 1}, "amount"},
               {:colon, {1, 7}},
               {:upper_ident, {1, 9}, "Int"},
               {:at, {1, 13}},
               {:ident, {1, 14}, "min"},
               {:lparen, {1, 17}},
               {:int, {1, 18}, 0},
               {:rparen, {1, 19}},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes capability declaration" do
      source = ~s[capability http.out("api.example.com")]
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:capability, {1, 1}},
               {:ident, {1, 12}, "http"},
               {:dot, {1, 16}},
               {:ident, {1, 17}, "out"},
               {:lparen, {1, 20}},
               {:string, {1, 21}, [{:literal, "api.example.com"}]},
               {:rparen, {1, 38}},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes parameterized type" do
      source = "Result[User, DbError]"
      assert {:ok, tokens} = Lexer.tokenize(source)

      assert [
               {:upper_ident, {1, 1}, "Result"},
               {:lbracket, {1, 7}},
               {:upper_ident, {1, 8}, "User"},
               {:comma, {1, 12}},
               {:upper_ident, {1, 14}, "DbError"},
               {:rbracket, {1, 21}},
               {:eof, _}
             ] = tokens
    end

    test "tokenizes fn ref" do
      assert {:ok, tokens} = Lexer.tokenize("&my_function")

      assert [
               {:ampersand, {1, 1}},
               {:ident, {1, 2}, "my_function"},
               {:eof, _}
             ] = tokens
    end
  end

  describe "tokenize/1 - hello.skein example" do
    test "tokenizes the Phase 1 acceptance example" do
      source = """
      module Hello {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }

        fn add(a: Int, b: Int) -> Int {
          a + b
        }

        fn classify(n: Int) -> String {
          match n > 0 {
            true  -> "positive"
            false -> "non-positive"
          }
        }
      }
      """

      assert {:ok, tokens} = Lexer.tokenize(source)

      # Verify key structural tokens are present
      token_types = Enum.map(tokens, &elem(&1, 0))
      assert :module in token_types
      assert :fn in token_types
      assert :match in token_types
      assert true in token_types
      assert false in token_types
      assert :eof in token_types

      # Count fn declarations
      fn_count = Enum.count(token_types, &(&1 == :fn))
      assert fn_count == 3

      # Verify we have string interpolation in the greet function
      string_tokens = Enum.filter(tokens, fn t -> elem(t, 0) == :string end)
      assert length(string_tokens) >= 1

      # First string should have interpolation
      {:string, _, segments} = hd(string_tokens)

      has_interpolation =
        Enum.any?(segments, fn
          {:interpolation, _} -> true
          _ -> false
        end)

      assert has_interpolation
    end
  end

  describe "tokenize/1 - error cases" do
    test "reports error on unexpected character" do
      assert {:error, [error]} = Lexer.tokenize("let x = ~")
      assert error.code == "E0001"
      assert error.message =~ "Unexpected character"
    end
  end

  describe "tokenize/1 - multiline strings" do
    test "tokenizes string spanning multiple lines" do
      source = ~s("line1\nline2")

      assert {:ok, [{:string, {1, 1}, [{:literal, "line1\nline2"}]}, {:eof, _}]} =
               Lexer.tokenize(source)
    end
  end

  describe "tokenize/1 - booleans" do
    test "tokenizes true as keyword" do
      assert {:ok, [{true, {1, 1}}, {:eof, _}]} = Lexer.tokenize("true")
    end

    test "tokenizes false as keyword" do
      assert {:ok, [{false, {1, 1}}, {:eof, _}]} = Lexer.tokenize("false")
    end
  end

  describe "tokenize/1 - minus vs arrow disambiguation" do
    test "minus followed by > becomes arrow" do
      assert {:ok, [{:arrow, {1, 1}}, {:eof, _}]} = Lexer.tokenize("->")
    end

    test "standalone minus stays as minus" do
      assert {:ok, [{:int, _, 1}, {:minus, _}, {:int, _, 2}, {:eof, _}]} =
               Lexer.tokenize("1 - 2")
    end
  end

  describe "tokenize/1 - pipe disambiguation" do
    test "|> becomes pipe operator" do
      assert {:ok, [{:pipe, {1, 1}}, {:eof, _}]} = Lexer.tokenize("|>")
    end

    test "standalone | stays as pipe_single" do
      assert {:ok, [{:pipe_single, {1, 1}}, {:eof, _}]} = Lexer.tokenize("|")
    end
  end
end
