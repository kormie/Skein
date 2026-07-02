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
    true false implement input output errors policy description
    state strategy child replay given expect assert
  )

  defp lower_ident_gen do
    gen all(
          first <- StreamData.member_of(Enum.to_list(?a..?z)),
          rest <-
            StreamData.list_of(
              StreamData.member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?_]),
              min_length: 0,
              max_length: 8
            )
        ) do
      name = List.to_string([first | rest])
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
              max_length: 8
            )
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
    gen all(
          left <- simple_expr_gen(),
          op <- StreamData.member_of(["+", "-", "*", ">", "<", "==", "!="]),
          right <- simple_expr_gen()
        ) do
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
    gen all(
          name <- lower_ident_gen(),
          type <- type_name_gen()
        ) do
      "#{name}: #{type}"
    end
  end

  defp fn_gen do
    gen all(
          name <- lower_ident_gen(),
          params <- StreamData.list_of(param_gen(), min_length: 0, max_length: 3),
          ret_type <- type_name_gen(),
          body <- body_expr_gen()
        ) do
      params_str = Enum.join(params, ", ")
      "fn #{name}(#{params_str}) -> #{ret_type} {\n    #{body}\n  }"
    end
  end

  defp module_gen do
    gen all(
          mod_name <- upper_ident_gen(),
          fns <- StreamData.list_of(fn_gen(), min_length: 1, max_length: 4)
        ) do
      body = Enum.map_join(fns, "\n  ", & &1)
      "module #{mod_name} {\n  #{body}\n}"
    end
  end

  # ------------------------------------------------------------------
  # Parser Properties
  # ------------------------------------------------------------------

  property "any generated module source lexes and parses successfully" do
    check all(source <- module_gen()) do
      assert {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{}} = Parser.parse(tokens)
    end
  end

  property "parsed module name matches the generated name" do
    check all(
            mod_name <- upper_ident_gen(),
            fn_decl <- fn_gen()
          ) do
      source = "module #{mod_name} {\n  #{fn_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{name: ^mod_name}} = Parser.parse(tokens)
    end
  end

  property "number of parsed fn declarations matches the number generated" do
    check all(
            mod_name <- upper_ident_gen(),
            fns <- StreamData.list_of(fn_gen(), min_length: 1, max_length: 4)
          ) do
      body = Enum.map_join(fns, "\n  ", & &1)
      source = "module #{mod_name} {\n  #{body}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      fn_count = Enum.count(decls, &match?(%AST.Fn{}, &1))
      assert fn_count == length(fns)
    end
  end

  property "every parsed function has a return type" do
    check all(source <- module_gen()) do
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      for %AST.Fn{} = f <- decls do
        assert %AST.TypeRef{} = f.return_type, "fn #{f.name} missing return type"
      end
    end
  end

  property "every parsed function has a block body" do
    check all(source <- module_gen()) do
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: decls}} = Parser.parse(tokens)

      for %AST.Fn{} = f <- decls do
        assert %AST.Block{} = f.body, "fn #{f.name} body should be a Block"
      end
    end
  end

  property "every AST node carries source location metadata" do
    check all(source <- module_gen()) do
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
    check all(
            mod_name <- upper_ident_gen(),
            fn_name <- lower_ident_gen(),
            left <- simple_expr_gen(),
            right <- simple_expr_gen()
          ) do
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
    check all(mod_name <- upper_ident_gen()) do
      source = "module #{mod_name} { }"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{name: ^mod_name, declarations: []}} = Parser.parse(tokens)
    end
  end

  # ------------------------------------------------------------------
  # Tool declaration properties (Phase 6c)
  # ------------------------------------------------------------------

  defp field_gen do
    gen all(
          name <- lower_ident_gen(),
          type <- type_name_gen()
        ) do
      "#{name}: #{type}"
    end
  end

  defp tool_name_gen do
    gen all(parts <- StreamData.list_of(upper_ident_gen(), min_length: 1, max_length: 3)) do
      Enum.join(parts, ".")
    end
  end

  defp tool_gen do
    gen all(
          tool_name <- tool_name_gen(),
          input_fields <- StreamData.list_of(field_gen(), min_length: 1, max_length: 3),
          output_fields <- StreamData.list_of(field_gen(), min_length: 1, max_length: 3),
          body <- body_expr_gen()
        ) do
      input_str = Enum.join(input_fields, "\n      ")
      output_str = Enum.join(output_fields, "\n      ")

      """
      tool #{tool_name} {
          input {
            #{input_str}
          }
          output {
            #{output_str}
          }
          implement {
            #{body}
          }
        }
      """
    end
  end

  property "any generated tool declaration lexes and parses successfully" do
    check all(
            mod_name <- upper_ident_gen(),
            tool_decl <- tool_gen()
          ) do
      source = "module #{mod_name} {\n  #{tool_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{declarations: [%AST.ToolDecl{}]}} = Parser.parse(tokens)
    end
  end

  property "parsed tool name matches the generated dotted name" do
    check all(
            mod_name <- upper_ident_gen(),
            tool_name <- tool_name_gen(),
            input_field <- field_gen(),
            output_field <- field_gen()
          ) do
      source = """
      module #{mod_name} {
        tool #{tool_name} {
          input { #{input_field} }
          output { #{output_field} }
          implement { 42 }
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [tool]}} = Parser.parse(tokens)
      assert %AST.ToolDecl{name: ^tool_name} = tool
    end
  end

  property "tool input/output field counts match generated counts" do
    check all(
            mod_name <- upper_ident_gen(),
            tool_name <- tool_name_gen(),
            input_fields <- StreamData.list_of(field_gen(), min_length: 1, max_length: 4),
            output_fields <- StreamData.list_of(field_gen(), min_length: 1, max_length: 4)
          ) do
      input_str = Enum.join(input_fields, "\n      ")
      output_str = Enum.join(output_fields, "\n      ")

      source = """
      module #{mod_name} {
        tool #{tool_name} {
          input { #{input_str} }
          output { #{output_str} }
          implement { 42 }
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [tool]}} = Parser.parse(tokens)
      assert length(tool.input) == length(input_fields)
      assert length(tool.output) == length(output_fields)
    end
  end

  property "tool declaration always has non-nil implement block" do
    check all(
            mod_name <- upper_ident_gen(),
            tool_decl <- tool_gen()
          ) do
      source = "module #{mod_name} {\n  #{tool_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [tool]}} = Parser.parse(tokens)
      assert %AST.Block{} = tool.implement
    end
  end

  property "tool declaration preserves source location metadata" do
    check all(
            mod_name <- upper_ident_gen(),
            tool_decl <- tool_gen()
          ) do
      source = "module #{mod_name} {\n  #{tool_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [tool]}} = Parser.parse(tokens)
      assert is_map(tool.meta)
      assert tool.meta.line >= 1
      assert tool.meta.col >= 1
    end
  end

  # ------------------------------------------------------------------
  # Scenario declaration properties (Phase 8a)
  # ------------------------------------------------------------------

  defp given_binding_gen do
    gen all(
          name <- lower_ident_gen(),
          value <- literal_expr_gen()
        ) do
      "#{name}: #{value}"
    end
  end

  defp scenario_gen do
    gen all(
          desc <-
            StreamData.string(Enum.to_list(?a..?z) ++ [?\s], min_length: 1, max_length: 20),
          bindings <- StreamData.list_of(given_binding_gen(), min_length: 1, max_length: 3),
          assertion_expr <- binary_expr_gen()
        ) do
      bindings_str = Enum.join(bindings, "\n      ")

      """
      scenario "#{desc}" {
          given {
            #{bindings_str}
          }
          expect {
            assert #{assertion_expr}
          }
        }
      """
    end
  end

  property "any generated scenario declaration lexes and parses successfully" do
    check all(
            mod_name <- upper_ident_gen(),
            scenario_decl <- scenario_gen()
          ) do
      source = "module #{mod_name} {\n  #{scenario_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{declarations: [%AST.Scenario{}]}} = Parser.parse(tokens)
    end
  end

  property "scenario description matches generated description" do
    check all(
            mod_name <- upper_ident_gen(),
            desc <-
              StreamData.string(Enum.to_list(?a..?z) ++ [?\s], min_length: 1, max_length: 15),
            binding <- given_binding_gen()
          ) do
      source = """
      module #{mod_name} {
        scenario "#{desc}" {
          given { #{binding} }
          expect { assert true }
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [scenario]}} = Parser.parse(tokens)
      assert scenario.description == desc
    end
  end

  property "scenario given var count matches generated bindings" do
    check all(
            mod_name <- upper_ident_gen(),
            bindings <- StreamData.list_of(given_binding_gen(), min_length: 1, max_length: 4)
          ) do
      bindings_str = Enum.join(bindings, "\n      ")

      source = """
      module #{mod_name} {
        scenario "test" {
          given { #{bindings_str} }
          expect { assert true }
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [scenario]}} = Parser.parse(tokens)
      assert length(scenario.given_vars) == length(bindings)
    end
  end

  property "scenario preserves source location metadata" do
    check all(
            mod_name <- upper_ident_gen(),
            scenario_decl <- scenario_gen()
          ) do
      source = "module #{mod_name} {\n  #{scenario_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [scenario]}} = Parser.parse(tokens)
      assert is_map(scenario.meta)
      assert scenario.meta.line >= 1
      assert scenario.meta.col >= 1
    end
  end

  # ------------------------------------------------------------------
  # Golden declaration properties (Phase 8a)
  # ------------------------------------------------------------------

  defp trace_file_gen do
    gen all(
          dir <- StreamData.member_of(["traces", "data", "test"]),
          name <-
            StreamData.string(Enum.to_list(?a..?z) ++ [?_], min_length: 1, max_length: 10)
        ) do
      "#{dir}/#{name}.json"
    end
  end

  defp golden_gen do
    gen all(
          desc <-
            StreamData.string(Enum.to_list(?a..?z) ++ [?\s], min_length: 1, max_length: 20),
          trace_file <- trace_file_gen(),
          assertion_expr <- binary_expr_gen()
        ) do
      """
      golden "#{desc}" from trace "#{trace_file}" {
          assert #{assertion_expr}
        }
      """
    end
  end

  property "any generated golden declaration lexes and parses successfully" do
    check all(
            mod_name <- upper_ident_gen(),
            golden_decl <- golden_gen()
          ) do
      source = "module #{mod_name} {\n  #{golden_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      assert {:ok, %AST.Module{declarations: [%AST.Golden{}]}} = Parser.parse(tokens)
    end
  end

  property "golden trace file matches generated path" do
    check all(
            mod_name <- upper_ident_gen(),
            trace_file <- trace_file_gen()
          ) do
      source = """
      module #{mod_name} {
        golden "test" from trace "#{trace_file}" {
          assert true
        }
      }
      """

      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [golden]}} = Parser.parse(tokens)
      assert golden.trace_file == trace_file
    end
  end

  property "golden preserves source location metadata" do
    check all(
            mod_name <- upper_ident_gen(),
            golden_decl <- golden_gen()
          ) do
      source = "module #{mod_name} {\n  #{golden_decl}\n}"
      {:ok, tokens} = Lexer.tokenize(source)
      {:ok, %AST.Module{declarations: [golden]}} = Parser.parse(tokens)
      assert is_map(golden.meta)
      assert golden.meta.line >= 1
      assert golden.meta.col >= 1
    end
  end
end
