defmodule Skein.Integration.ScenarioEnvelopeTest do
  @moduledoc """
  Tool effect-summary analysis and scenario envelope coverage (#281).

  A scenario that calls a tool must declare a `capability tool.use(T)` envelope
  covering the tool's transitive effect summary (effects launder through helper
  fns). The new diagnostic is E0028.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.{Analyzer, Lexer, Parser}

  defp envelope_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    errs =
      case Analyzer.analyze(ast, source_text: source) do
        {:error, e} -> e
        {:ok, _} -> []
        {:ok, _, w} -> w
      end

    Enum.filter(errs, &(&1.code == "E0028"))
  end

  describe "envelope coverage" do
    test "a complete envelope (effect reached through a helper) is accepted" do
      assert [] =
               envelope_errors("""
               module M {
                 capability tool.use(Billing.Refund)

                 fn charge() -> Result[HttpResponse, HttpError] {
                   http.get("https://api.stripe.com/v1/charges")
                 }

                 tool Billing.Refund {
                   input { ticket_id: String }
                   output { status: String }
                   implement {
                     let r = charge()!
                     { status: "ok" }
                   }
                 }

                 scenario "refund" {
                   capability tool.use(Billing.Refund) {
                     capability http.out("api.stripe.com") {
                       implement(req: HttpRequest) -> Result[HttpResponse, HttpError] {
                         Ok(HttpResponse { status: 200, body: {}, headers: {} })
                       }
                     }
                   }
                   expect {
                     let result = tool.call(Billing.Refund, { ticket_id: "t1" })!
                     assert result.status == "ok"
                   }
                 }
               }
               """)
    end

    test "an envelope missing the transitively-required http.out is E0028" do
      errs =
        envelope_errors("""
        module M {
          capability tool.use(Billing.Refund)

          fn charge() -> Result[HttpResponse, HttpError] {
            http.get("https://api.stripe.com/v1/charges")
          }

          tool Billing.Refund {
            input { ticket_id: String }
            output { status: String }
            implement {
              let r = charge()!
              { status: "ok" }
            }
          }

          scenario "refund" {
            capability tool.use(Billing.Refund) {
              capability uuid {
                implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }
              }
            }
            expect {
              let result = tool.call(Billing.Refund, { ticket_id: "t1" })!
              assert result.status == "ok"
            }
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.message =~ "http.out" and e.message =~ "Billing.Refund" end)
    end

    test "calling a tool with no envelope at all is E0028" do
      errs =
        envelope_errors("""
        module M {
          capability tool.use(Billing.Refund)

          tool Billing.Refund {
            input { ticket_id: String }
            output { status: String }
            implement { Ok({ status: "ok" }) }
          }

          scenario "refund" {
            expect {
              let result = tool.call(Billing.Refund, { ticket_id: "t1" })!
              assert result.status == "ok"
            }
          }
        }
        """)

      assert Enum.any?(errs, fn e ->
               e.message =~ "declares no" and e.message =~ "Billing.Refund"
             end)
    end

    test "uuid/instant effects in the tool require matching nested capabilities" do
      errs =
        envelope_errors("""
        module M {
          capability tool.use(Ids.New)

          tool Ids.New {
            input { kind: String }
            output { id: Uuid }
            implement { Ok({ id: uuid.new() }) }
          }

          scenario "ids" {
            capability tool.use(Ids.New) { }
            expect {
              let result = tool.call(Ids.New, { kind: "x" })!
              assert true
            }
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.message =~ "uuid" end)
    end

    test "a pure tool (no controlled effects) needs only the bare envelope" do
      assert [] =
               envelope_errors("""
               module M {
                 capability tool.use(Math.Add)

                 tool Math.Add {
                   input { a: Int, b: Int }
                   output { sum: Int }
                   implement { Ok({ sum: 1 }) }
                 }

                 scenario "add" {
                   capability tool.use(Math.Add) { }
                   expect {
                     let result = tool.call(Math.Add, { a: 1, b: 2 })!
                     assert true
                   }
                 }
               }
               """)
    end
  end

  describe "effect summary is closed under helper-call composition" do
    @namespaces %{
      "http.get(\"https://x\")" => "http.out",
      "uuid.new()" => "uuid",
      "instant.now()" => "instant",
      "llm.chat(\"m\", \"s\", \"i\")" => "model"
    }

    property "an effect called through a chain of helpers appears in the tool summary" do
      check all(
              {call, cap} <- StreamData.member_of(Map.to_list(@namespaces)),
              depth <- StreamData.integer(1..3)
            ) do
        helpers =
          for i <- 1..depth do
            next = if i < depth, do: "h#{i + 1}()", else: call
            "  fn h#{i}() -> Int { let _x = #{next}\n    0 }"
          end
          |> Enum.join("\n")

        source = """
        module M {
          capability tool.use(T.Deep)
        #{helpers}
          tool T.Deep {
            input { x: Int }
            output { ok: Bool }
            implement { let _r = h1()
              Ok({ ok: true }) }
          }
          scenario "deep" {
            capability tool.use(T.Deep) { }
            expect {
              let result = tool.call(T.Deep, { x: 1 })!
              assert true
            }
          }
        }
        """

        errs = envelope_errors(source)
        # The bare envelope omits the deep effect, so coverage must flag it.
        assert Enum.any?(errs, fn e -> e.message =~ cap end),
               "expected missing-#{cap} E0028 for call #{call} at depth #{depth}"
      end
    end
  end
end
