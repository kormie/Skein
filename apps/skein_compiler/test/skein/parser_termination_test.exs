defmodule Skein.ParserTerminationTest do
  @moduledoc """
  Pins the expression-termination rules of spec §3.12 (#318).

  The parser is newline-blind except for four postfix continuations that
  terminate at a newline: a call `(` (#311), a type-argument `[`, and the
  postfix unwrap operators `!`/`?` never continue the previous expression
  when they start a new line. Everything else — field access `.`, pipe
  `|>`, and the binary operators — continues across newlines on either
  side of the operator.

  Each rule here is a CI tripwire: a parser change that flips one of these
  is a spec change and must fail loudly.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.AST

  defp parse!(source) do
    {:ok, tokens} = Skein.Lexer.tokenize(source)
    {:ok, ast} = Skein.Parser.parse(tokens)
    ast
  end

  defp fn_body!(source) do
    %AST.Module{declarations: decls} = parse!(source)
    %AST.Fn{body: %AST.Block{expressions: exprs}} = List.first(decls)
    exprs
  end

  describe "continuations across newlines (legal)" do
    test ".field continues when the dot starts the next line" do
      exprs =
        fn_body!("""
        module M {
          fn f(u: User) -> String {
            u
            .name
          }
        }
        """)

      assert [%AST.FieldAccess{subject: %AST.Identifier{name: "u"}, field: "name"}] = exprs
    end

    test ".field continues when the line ends with the dot" do
      exprs =
        fn_body!("""
        module M {
          fn f(u: User) -> String {
            u.
            name
          }
        }
        """)

      assert [%AST.FieldAccess{field: "name"}] = exprs
    end

    test "a leading |> continues the pipe" do
      exprs =
        fn_body!("""
        module M {
          fn f(x: Int) -> Int {
            x
            |> double()
          }
        }
        """)

      assert [%AST.Pipe{left: %AST.Identifier{name: "x"}}] = exprs
    end

    test "a leading minus continues as subtraction, not a new negation statement" do
      exprs =
        fn_body!("""
        module M {
          fn f() -> Int {
            1
            - 2
          }
        }
        """)

      assert [%AST.BinaryOp{op: :-}] = exprs
    end

    property "binary operators continue whether the operator trails or leads the line break" do
      operators = ~w(+ - * / == != < > <= >= && ||)

      check all(op <- StreamData.member_of(operators)) do
        trailing =
          fn_body!("""
          module M {
            fn f(a: Int, b: Int) -> Int {
              a #{op}
                b
            }
          }
          """)

        leading =
          fn_body!("""
          module M {
            fn f(a: Int, b: Int) -> Int {
              a
              #{op} b
            }
          }
          """)

        expected = String.to_atom(op)
        assert [%AST.BinaryOp{op: ^expected}] = trailing
        assert [%AST.BinaryOp{op: ^expected}] = leading
      end
    end
  end

  describe "terminations at newlines (a line-initial token never continues)" do
    test "a line-initial ( is the grouping paren of the next statement (#311)" do
      exprs =
        fn_body!("""
        module M {
          fn f() -> Int {
            let x = 1
            (2 + 3)
          }
        }
        """)

      assert [%AST.Let{name: "x", value: %AST.IntLit{value: 1}}, %AST.BinaryOp{op: :+}] = exprs
    end

    test "a line-initial [ is a list literal, even when it opens with an upper identifier" do
      exprs =
        fn_body!("""
        module M {
          fn f(s: Status) -> Status {
            let x = s
            [Status.Active]
          }
        }
        """)

      assert [%AST.Let{name: "x"}, %AST.ListLit{}] = exprs
    end

    test "a line-initial ! is the prefix not of the next expression" do
      exprs =
        fn_body!("""
        module M {
          fn f(a: Bool, b: Bool) -> Bool {
            let x = a
            !b
          }
        }
        """)

      assert [
               %AST.Let{name: "x", value: %AST.Identifier{name: "a"}},
               %AST.UnaryOp{op: :not, operand: %AST.Identifier{name: "b"}}
             ] = exprs
    end

    test "a line-initial ! before a paren is prefix not of the group, not the removed !( form" do
      exprs =
        fn_body!("""
        module M {
          fn f(a: Bool, b: Bool, c: Bool) -> Bool {
            let x = a
            !(b && c)
          }
        }
        """)

      assert [%AST.Let{name: "x"}, %AST.UnaryOp{op: :not, operand: %AST.BinaryOp{op: :&&}}] =
               exprs
    end

    test "a line-initial ? never propagates the previous expression" do
      source = """
      module M {
        fn f() -> Result[Int, String] {
          let v = g()
          ?
          Ok(v)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)

      # Before #318 this parsed as `g()?`. Now the `?` belongs to the next
      # statement, where it cannot start an expression: a parse error, never
      # a silent propagate.
      assert {:error, [error | _]} = Skein.Parser.parse(tokens)
      assert error.code == "E0001"
    end

    test "same-line postfix ! still unwraps (the rule is about newlines only)" do
      exprs =
        fn_body!("""
        module M {
          fn f(k: String) -> String {
            memory.get(k)!
          }
        }
        """)

      assert [%AST.UnaryOp{op: :unwrap, operand: %AST.Call{}}] = exprs
    end

    test "a line-initial [ never becomes a type-parameterized call" do
      exprs =
        fn_body!("""
        module M {
          fn f(v: Json) -> Json {
            let x = v
            [Int]
          }
        }
        """)

      assert [%AST.Let{name: "x"}, %AST.ListLit{}] = exprs
    end
  end
end
