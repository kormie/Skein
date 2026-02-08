defmodule Skein.ParserPropertyTest do
  @moduledoc """
  Property-based tests for the Skein parser.

  Generates valid Skein source programs, lexes them, and verifies the parser
  produces well-formed ASTs.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.AST

  # ------------------------------------------------------------------
  # Generators: produce valid Skein source strings
  # ------------------------------------------------------------------

  @keywords ~w(
    module fn let match type enum handler agent tool capability
    supervisor test scenario golden on emit transition stop suspend
    resume true false implement input output errors policy description
    state strategy child replay given expect assert
  )

  defp lower_ident_gen do
    gen all first <- StreamData.member_of(Enum.to_list(?a..?z)),
            rest <-
              StreamData.list_of(
                StreamData.member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_]),
                min_length: 0,
                max_length: 8
              ) do
      name = List.to_string([first | rest])
      if name in @keywords, do: "z" <> name, else: name
    end
  end

  defp upper_ident_gen do
    gen all first <- StreamData.member_of(Enum.to_list(?A..?Z)),
            rest <-
              StreamData.list_of(
                StreamData.member_of(
                  Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9)
                ),
                min_length: 0,
                max_length: 8
              ) do
      List.to_string([first | rest])
    end
  end

  defp type_name_gen do
    StreamData.member_of(["Int", "String", "Bool", "Float"])
  end

  defp literal_expr_gen do
    StreamData.one_of([
      StreamData.map(StreamData.positive_integer(), &Integer.to_string/1),
      StreamData.constant("true"),
      StreamData.constant("false"),
      StreamData.map(
        StreamData.string(Enum.to_list(?a..?z) ++ [?\s], min_length: 0, max_length: 10),
        &"\"#{&1}\""
      )
    ])
  end

  defp simple_expr_gen do
    StreamData.one_of([
      literal_expr_gen(),
      lower_ident_gen()
    ])
  end

  defp binary_expr_gen do
    gen all left <- simple_expr_gen(),
            op <- StreamData.member_of(["+", "-", "*", ">", "<", "==", "!="]),
            right <- simple_expr_gen() do
      "#{left} #{op} #{right}"
    end
  end

  defp body_expr_gen do
    StreamData.one_of([
      simple_expr_gen(),
      binary_expr_gen()
    ])
  end

  defp param_gen do
    gen all name <- lower_ident_gen(),
            type <- type_name_gen() do
      "#{name}: #{type}"
    end
  end

  defp fn_gen do
    gen all name <- lower_ident_gen(),
            params <- StreamData.list_of(param_gen(), min_length: 0, max_length: 3),
            ret_type <- type_name_gen(),
            body <- body_expr_gen() do
      params_str = Enum.join(params, ", ")
      "fn #{name}(#{params_str}) -> #{ret_type} {\n    #{body}\n  }"
    end
  end

  defp module_gen do
    gen all mod_name <- upper_ident_gen(),
            fns <- StreamData.list_of(fn_gen(), min_length: 1, max_length: 4) do
      body = Enum.map_join(fns, "\n  ", & &1)
      "module #{mod_name} {\n  #{body}\n}"
    end
  end

  # ------------------------------------------------------------------
  # Parser Properties
  # ------------------------------------------------------------------

  property "any generated module source lexes and parses successfully" do
    check all source <- module_gen() do
      assert {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{}} = Parser.parse(tokens)
    end
  end

  property "parsed module name matches the generated name" do
    check all mod_name <- upper_ident_gen(),
            fn_decl <- fn_gen() do
      source = "module #{mod_name} {\n  #{fn_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{name: ^mod_name}} = Parser.parse(tokens)
    end
  end

  property "number of parsed fn declarations matches the number generated" do
    check all mod_name <- upper_ident_gen(),
            fns <- StreamData.list_of(fn_gen(), min_length: 1, max_length: 4) do
      body = Enum.map_join(fns, "\n  ", & &1)
      source = "module #{mod_name} {\n  #{body}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      fn_count = Enum.count(decls, &match?(%AST.Fn{}, &1))
      assert fn_count == length(fns)
    end
  end

  property "every parsed function has a return type" do
    check all source <- module_gen() do
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      for %AST.Fn{} = f <- decls do
        assert %AST.TypeRef{} = f.return_type, "fn #{f.name} missing return type"
      end
    end
  end

  property "every parsed function has a block body" do
    check all source <- module_gen() do
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      for %AST.Fn{} = f <- decls do
        assert %AST.Block{} = f.body, "fn #{f.name} body should be a Block"
      end
    end
  end

  property "every AST node carries source location metadata" do
    check all source <- module_gen() do
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{} = mod} = Parser.parse(tokens)

      assert is_map(mod.meta)
      assert Map.has_key?(mod.meta, :line)
      assert Map.has_key?(mod.meta, :col)

      for %AST.Fn{} = f <- mod.declarations do
        assert is_map(f.meta)
        assert f.meta.line >= 1
        assert f.meta.col >= 1
      end
    end
  end

  property "match expression on booleans always produces exactly 2 arms" do
    check all mod_name <- upper_ident_gen(),
            fn_name <- lower_ident_gen(),
            left <- simple_expr_gen(),
            right <- simple_expr_gen() do
      source = """
      module #{mod_name} {
        fn #{fn_name}(n: Int) -> String {
          match n > 0 {
            true -> #{left}
            false -> #{right}
          }
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [f]}} = Parser.parse(tokens)
      assert %AST.Block{expressions: [%AST.Match{arms: arms}]} = f.body
      assert length(arms) == 2
    end
  end

  property "empty module parses with zero declarations" do
    check all mod_name <- upper_ident_gen() do
      source = "module #{mod_name} { }"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{name: ^mod_name, declarations: []}} = Parser.parse(tokens)
    end
  end
end
