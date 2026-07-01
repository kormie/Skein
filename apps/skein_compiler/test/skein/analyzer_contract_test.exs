defmodule Skein.AnalyzerContractTest do
  @moduledoc """
  B6 (#295): tool `implement` bodies are checked against the tool's
  `Result[output, error]` contract, scenario `implement` providers are checked
  against their capability's provider contract, and purity (E0029) is
  transitive through local function calls and references.
  """
  use ExUnit.Case, async: true

  alias Skein.{Analyzer, Lexer, Parser}

  defp analyze_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast, source_text: source) do
      {:error, errors} -> errors
      {:ok, _} -> []
      {:ok, _, _warnings} -> []
    end
  end

  defp errors_with_code(source, code) do
    source |> analyze_errors() |> Enum.filter(&(&1.code == code))
  end

  # ------------------------------------------------------------------
  # Tool implement bodies must return Result[output, error]
  # ------------------------------------------------------------------

  describe "tool implement Result contract" do
    test "a bare string body is E0020 (must return a Result)" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ping)
            tool Ping {
              input { q: String }
              output { r: String }
              implement { "ok" }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "Ping" and e.message =~ "Result" and e.message =~ "String"
             end)
    end

    test "a bare map body is E0020 (the output must be wrapped in Ok)" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ping)
            tool Ping {
              input { q: String }
              output { r: String }
              implement { { r: "ok" } }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "Ping" and e.message =~ "Result" end)
    end

    test "Ok payload with a field the output does not declare is E0020" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ping)
            tool Ping {
              input { q: String }
              output { r: String }
              implement { Ok({ wrong: "x" }) }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "wrong" and e.message =~ "Ping" end)
    end

    test "Ok payload missing a required output field is E0020" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ping)
            tool Ping {
              input { q: String }
              output {
                r: String
                n: Int
              }
              implement { Ok({ r: "x" }) }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "n" and e.message =~ "Ping" end)
    end

    test "Ok payload field of the wrong type is E0020" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Count)
            tool Count {
              input { q: String }
              output { n: Int }
              implement { Ok({ n: "not an int" }) }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "n" and e.message =~ "Int" end)
    end

    test "an absent Option output field is fine; a present one takes the bare inner value" do
      assert [] =
               errors_with_code(
                 """
                 module M {
                   capability tool.use(Ping)
                   tool Ping {
                     input { q: String }
                     output {
                       r: String
                       note: Option[String]
                     }
                     implement { Ok({ r: "x" }) }
                   }
                 }
                 """,
                 "E0020"
               )

      assert [] =
               errors_with_code(
                 """
                 module M {
                   capability tool.use(Ping)
                   tool Ping {
                     input { q: String }
                     output {
                       r: String
                       note: Option[String]
                     }
                     implement { Ok({ r: "x", note: "y" }) }
                   }
                 }
                 """,
                 "E0020"
               )
    end

    test "a present Option output field of the wrong inner type is E0020" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ping)
            tool Ping {
              input { q: String }
              output {
                r: String
                note: Option[String]
              }
              implement { Ok({ r: "x", note: 42 }) }
            }
          }
          """,
          "E0020"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "note" and e.message =~ "String" end)
    end

    test "the canonical match-on-effect body with Ok/Err arms is clean" do
      assert [] =
               analyze_errors("""
               module M {
                 capability tool.use(Fetch)
                 capability http.out("api.example.com")
                 tool Fetch {
                   input { path: String }
                   output { status: Int }
                   errors { FetchError }
                   implement {
                     match http.get("https://api.example.com/x") {
                       Ok(r) -> Ok({ status: r.status })
                       Err(e) -> Err(FetchError.from(e))
                     }
                   }
                 }
               }
               """)
    end

    test "a body delegating to a Result-returning helper is clean" do
      assert [] =
               analyze_errors("""
               module M {
                 capability tool.use(Ping)
                 fn build(q: String) -> Result[Map, String] {
                   Ok({ r: q })
                 }
                 tool Ping {
                   input { q: String }
                   output { r: String }
                   implement { build(q) }
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Scenario provider contracts (E0038)
  # ------------------------------------------------------------------

  defp uuid_scenario(provider) do
    """
    module M {
      capability tool.use(Ids.New)
      capability uuid

      tool Ids.New {
        input { kind: String }
        output { id: Uuid }
        implement { Ok({ id: uuid.new() }) }
      }

      scenario "controlled" {
        capability tool.use(Ids.New) {
          capability uuid {
            #{provider}
          }
        }
        expect {
          let r = tool.call(Ids.New, { kind: "x" })!
          assert true
        }
      }
    }
    """
  end

  describe "provider contract (E0038)" do
    test "the canonical uuid provider is clean" do
      source =
        uuid_scenario(
          ~s|implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }|
        )

      assert [] = errors_with_code(source, "E0038")
      assert [] = errors_with_code(source, "E0020")
    end

    test "a uuid provider with the wrong return type is E0038" do
      errs = errors_with_code(uuid_scenario(~s|implement() -> String { "x" }|), "E0038")

      assert Enum.any?(errs, fn e ->
               e.message =~ "uuid" and e.fix_code =~ "implement() -> Uuid"
             end)
    end

    test "a uuid provider with the wrong arity is E0038" do
      errs =
        errors_with_code(
          uuid_scenario(
            ~s|implement(x: String) -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }|
          ),
          "E0038"
        )

      assert Enum.any?(errs, &(&1.message =~ "uuid"))
    end

    test "an http.out provider with the wrong param type is E0038" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Fetch)
            capability http.out("api.example.com")

            tool Fetch {
              input { path: String }
              output { status: Int }
              implement {
                match http.get("https://api.example.com/x") {
                  Ok(r) -> Ok({ status: r.status })
                  Err(_) -> Ok({ status: 0 })
                }
              }
            }

            scenario "controlled" {
              capability tool.use(Fetch) {
                capability http.out("api.example.com") {
                  implement(req: String) -> Result[HttpResponse, HttpError] {
                    Ok(HttpResponse { status: 200, body: {}, headers: {} })
                  }
                }
              }
              expect {
                let r = tool.call(Fetch, { path: "x" })!
                assert true
              }
            }
          }
          """,
          "E0038"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "http.out" and e.fix_code =~ "HttpRequest"
             end)
    end

    test "a model provider with the wrong success type is E0038" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ask)
            capability model("anthropic", "claude-opus-4-8")

            tool Ask {
              input { q: String }
              output { answer: String }
              implement {
                match llm.chat("claude-opus-4-8", "sys", "q") {
                  Ok(text) -> Ok({ answer: text })
                  Err(_) -> Ok({ answer: "error" })
                }
              }
            }

            scenario "controlled" {
              capability tool.use(Ask) {
                capability model("anthropic", "claude-opus-4-8") {
                  implement(req: LlmRequest) -> Result[String, LlmError] {
                    Ok("x")
                  }
                }
              }
              expect {
                let r = tool.call(Ask, { q: "hi" })!
                assert true
              }
            }
          }
          """,
          "E0038"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "model" and e.fix_code =~ "LlmResponse"
             end)
    end

    test "an implement block under a capability with no provider contract is E0038" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ids.New)
            capability uuid

            tool Ids.New {
              input { kind: String }
              output { id: Uuid }
              implement { Ok({ id: uuid.new() }) }
            }

            scenario "controlled" {
              capability tool.use(Ids.New) {
                capability uuid {
                  implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }
                }
                capability store {
                  implement() -> String { "x" }
                }
              }
              expect {
                let r = tool.call(Ids.New, { kind: "x" })!
                assert true
              }
            }
          }
          """,
          "E0038"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "store" and e.message =~ "implement"
             end)
    end

    test "the canonical http.out and model providers are clean" do
      assert [] =
               errors_with_code(
                 """
                 module M {
                   capability tool.use(Fetch)
                   capability http.out("api.example.com")

                   tool Fetch {
                     input { path: String }
                     output { status: Int }
                     implement {
                       match http.get("https://api.example.com/x") {
                         Ok(r) -> Ok({ status: r.status })
                         Err(_) -> Ok({ status: 0 })
                       }
                     }
                   }

                   scenario "controlled" {
                     capability tool.use(Fetch) {
                       capability http.out("api.example.com") {
                         implement(req: HttpRequest) -> Result[HttpResponse, HttpError] {
                           Ok(HttpResponse { status: 200, body: {}, headers: {} })
                         }
                       }
                     }
                     expect {
                       let r = tool.call(Fetch, { path: "x" })!
                       assert true
                     }
                   }
                 }
                 """,
                 "E0038"
               )
    end
  end

  # ------------------------------------------------------------------
  # Provider body typing (E0020)
  # ------------------------------------------------------------------

  describe "provider body typing" do
    test "a provider body that does not produce the declared return type is E0020" do
      errs = errors_with_code(uuid_scenario("implement() -> Uuid { 42 }"), "E0020")

      assert Enum.any?(errs, fn e ->
               e.message =~ "Provider" and e.message =~ "Uuid" and e.message =~ "Int"
             end)
    end

    test "type errors inside a provider body surface" do
      errs =
        analyze_errors(
          uuid_scenario("""
          implement() -> Uuid {
            let n = String.length(42)
            Uuid.parse("00000000-0000-4000-8000-000000000001")!
          }
          """)
        )

      assert Enum.any?(errs, &(&1.code == "E0020"))
    end
  end

  # ------------------------------------------------------------------
  # Transitive purity (E0029)
  # ------------------------------------------------------------------

  describe "transitive purity" do
    test "an effect reached through a helper fn in a test body is E0029" do
      errs =
        errors_with_code(
          """
          module M {
            capability uuid
            fn mint() -> Uuid { uuid.new() }
            test "t" {
              let id = mint()
              assert true
            }
          }
          """,
          "E0029"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "uuid.new" and e.message =~ "mint" end)
    end

    test "an effect reached through two helper levels is E0029 with the call chain" do
      errs =
        errors_with_code(
          """
          module M {
            capability http.out("api.example.com")
            fn outer() -> Int { inner() }
            fn inner() -> Int {
              match http.get("https://api.example.com/x") {
                Ok(r) -> r.status
                Err(_) -> 0
              }
            }
            test "t" {
              assert outer() == 0
            }
          }
          """,
          "E0029"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "http.get" and e.message =~ "outer" and e.message =~ "inner"
             end)
    end

    test "a recursive helper terminates and stays pure" do
      assert [] =
               errors_with_code(
                 """
                 module M {
                   fn countdown(n: Int) -> Int {
                     match n == 0 {
                       true -> 0
                       false -> countdown(n - 1)
                     }
                   }
                   test "t" { assert countdown(3) == 0 }
                 }
                 """,
                 "E0029"
               )
    end

    test "an effect reached through a helper in a provider body is E0029" do
      errs =
        errors_with_code(
          """
          module M {
            capability tool.use(Ids.New)
            capability uuid

            fn sneak() -> Uuid { uuid.new() }

            tool Ids.New {
              input { kind: String }
              output { id: Uuid }
              implement { Ok({ id: uuid.new() }) }
            }

            scenario "controlled" {
              capability tool.use(Ids.New) {
                capability uuid {
                  implement() -> Uuid { sneak() }
                }
              }
              expect {
                let r = tool.call(Ids.New, { kind: "x" })!
                assert true
              }
            }
          }
          """,
          "E0029"
        )

      assert Enum.any?(errs, fn e ->
               e.message =~ "uuid.new" and e.message =~ "sneak" and e.message =~ "implement"
             end)
    end

    test "a reference to an effectful fn in a test body is E0029" do
      errs =
        errors_with_code(
          """
          module M {
            capability uuid
            fn mint() -> Uuid { uuid.new() }
            test "t" {
              let f = &mint
              assert true
            }
          }
          """,
          "E0029"
        )

      assert Enum.any?(errs, fn e -> e.message =~ "uuid.new" and e.message =~ "mint" end)
    end

    test "a pure helper chain stays clean" do
      assert [] =
               errors_with_code(
                 """
                 module M {
                   fn double(n: Int) -> Int { twice(n) }
                   fn twice(n: Int) -> Int { n + n }
                   test "t" { assert double(2) == 4 }
                 }
                 """,
                 "E0029"
               )
    end
  end
end
