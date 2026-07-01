defmodule Skein.Integration.PureContextTest do
  @moduledoc """
  Purity of `test` bodies and scenario `implement` providers (#273): effects
  belong in `scenario`, never `test`; provider `implement` blocks must be pure.
  The diagnostic is E0029.
  """
  use ExUnit.Case, async: true

  alias Skein.{Analyzer, Lexer, Parser}

  defp purity_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    errs =
      case Analyzer.analyze(ast, source_text: source) do
        {:error, e} -> e
        {:ok, _} -> []
        {:ok, _, w} -> w
      end

    Enum.filter(errs, &(&1.code == "E0029"))
  end

  describe "test purity" do
    test "an effect call inside a `test` body is E0029" do
      errs =
        purity_errors("""
        module M {
          capability model("anthropic", "claude-opus-4-8")
          test "calls llm" {
            let r = llm.chat("claude-opus-4-8", "sys", "hi")!
            assert String.length(r) > 0
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.message =~ "llm.chat" and e.message =~ "test" end)
    end

    test "uuid.new() inside a `test` body is E0029" do
      errs =
        purity_errors("""
        module M {
          capability uuid
          test "makes an id" {
            let id = uuid.new()
            assert true
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.message =~ "uuid.new" end)
    end

    test "a pure `test` body (local calls, no effects) is clean" do
      assert [] =
               purity_errors("""
               module M {
                 fn add(a: Int, b: Int) -> Int { a + b }
                 test "adds" { assert add(1, 2) == 3 }
               }
               """)
    end

    test "the same effect is allowed in a `scenario`" do
      assert [] =
               purity_errors("""
               module M {
                 capability model("anthropic", "claude-opus-4-8")
                 scenario "calls llm" {
                   expect {
                     let r = llm.chat("claude-opus-4-8", "sys", "hi")!
                     assert String.length(r) > 0
                   }
                 }
               }
               """)
    end
  end

  describe "provider implement purity" do
    test "an effect call inside an `implement` provider block is E0029" do
      errs =
        purity_errors("""
        module M {
          capability tool.use(Ids.New)

          tool Ids.New {
            input { kind: String }
            output { id: Uuid }
            implement { Ok({ id: uuid.new() }) }
          }

          scenario "ids" {
            capability tool.use(Ids.New) {
              capability uuid {
                implement() -> Uuid { uuid.new() }
              }
            }
            expect {
              let result = tool.call(Ids.New, { kind: "x" })!
              assert true
            }
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.message =~ "implement" and e.message =~ "uuid.new" end)
    end

    test "a pure `implement` provider block is clean" do
      assert [] =
               purity_errors("""
               module M {
                 capability tool.use(Ids.New)

                 tool Ids.New {
                   input { kind: String }
                   output { id: String }
                   implement { Ok({ id: "static" }) }
                 }

                 scenario "ids" {
                   capability tool.use(Ids.New) {
                     capability uuid {
                       implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }
                     }
                   }
                   expect {
                     let result = tool.call(Ids.New, { kind: "x" })!
                     assert true
                   }
                 }
               }
               """)
    end
  end
end
