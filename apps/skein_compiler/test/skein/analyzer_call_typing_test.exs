defmodule Skein.AnalyzerCallTypingTest do
  @moduledoc """
  Argument typing for local and effect calls, and the callable type carried
  by `&fn` references (#292 / B3).

  Before B3, local calls checked arity only, effect calls checked arity
  bounds only, and a `&fn` reference inferred `:unknown` — so a wrong-typed
  argument compiled and crashed (or silently misbehaved) at runtime. Now:

    * local calls type-check every argument against the declared parameter
    * effect calls type-check documented source arguments (spec §6)
    * `&fn` carries `{:fn, params, ret}` from the referenced signature
    * higher-order stdlib slots (`List.map`/`filter`/`reduce`, ...) expect a
      callable of the right shape and reject wrong-arity / wrong-return /
      non-function callbacks
    * named arguments desugar to positional form first, so they route
      through the very same checks
  """
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  describe "local call argument typing (E0020)" do
    test "a wrong-typed argument is a structured diagnostic naming the parameter" do
      errors =
        analyze_errors("""
        module M {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn run() -> Int {
            add("one", 2)
          }
        }
        """)

      assert [%Skein.Error{code: "E0020"} = error] = errors
      assert error.severity == :error
      assert error.message =~ "'a'"
      assert error.message =~ "Int"
      assert error.message =~ "String"
      assert error.fix_hint != nil
      assert error.fix_code != nil
    end

    test "correctly typed arguments pass" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int {
                   a + b
                 }

                 fn run() -> Int {
                   add(1, 2)
                 }
               }
               """)
    end

    test "named arguments route through the same argument checks" do
      errors =
        analyze_errors("""
        module M {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn run() -> Int {
            add(b: "two", a: 1)
          }
        }
        """)

      assert [%Skein.Error{code: "E0020"} = error] = errors
      assert error.message =~ "'b'"
      assert error.message =~ "Int"
      assert error.message =~ "String"
    end

    test "a mismatched record argument is rejected" do
      errors =
        analyze_errors("""
        module M {
          type Customer {
            name: String
          }

          type Invoice {
            total: Int
          }

          fn describe(c: Customer) -> String {
            c.name
          }

          fn run(inv: Invoice) -> String {
            describe(inv)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Customer" and e.message =~ "Invoice"
             end)
    end

    test "the sanctioned dynamic seam still flows into typed parameters" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("cache")

                 fn bump(n: Int) -> Int {
                   n + 1
                 }

                 fn run() -> Int {
                   bump(memory.get("count")!)
                 }
               }
               """)
    end
  end

  describe "effect call argument typing (E0020)" do
    test "http.get with a non-String url is rejected" do
      errors =
        analyze_errors("""
        module M {
          capability http.out("api.example.com")

          fn fetch() -> Result[String, HttpError] {
            http.get(42)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "http.get" and e.message =~ "url"
             end)
    end

    test "memory.put with a non-String key is rejected" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("cache")

          fn save() -> Result[String, MemoryError] {
            memory.put(1, "v")
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "memory.put" and e.message =~ "key"
             end)
    end

    test "correctly typed effect arguments pass (payload slots stay open)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn ship(payload: Json) -> Result[Json, HttpError] {
                   http.post("https://api.example.com/items", payload)
                 }
               }
               """)
    end

    test "timer.after with a non-Int delay is rejected" do
      errors =
        analyze_errors("""
        module M {
          capability timer("jobs")

          fn ping() -> String {
            "pong"
          }

          fn schedule() -> String {
            timer.after("soon", "ping", &ping)
            "scheduled"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "timer.after" and e.message =~ "delay_ms"
             end)
    end

    test "process.spawn rejects a work fn that takes arguments" do
      errors =
        analyze_errors("""
        module M {
          capability process.spawn("workers")

          fn resize(width: Int) -> Int {
            width / 2
          }

          fn kick() -> String {
            process.spawn("resize", &resize)
            "spawned"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "process.spawn" and e.message =~ "work"
             end)
    end

    test "process.spawn accepts a zero-argument work fn" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability process.spawn("workers")

                 fn cleanup() -> String {
                   "done"
                 }

                 fn kick() -> String {
                   process.spawn("cleanup", &cleanup)
                   "spawned"
                 }
               }
               """)
    end
  end

  describe "&fn carries a callable type" do
    test "returning a fn reference where a value type is declared is a type mismatch" do
      errors =
        analyze_errors("""
        module M {
          fn base() -> Int {
            1
          }

          fn get_base() -> Int {
            &base
          }
        }
        """)

      assert [%Skein.Error{code: "E0020"} = error] = errors
      assert error.message =~ "Int"
      assert error.message =~ "fn() -> Int"
    end

    test "a reference to an undefined fn stays unverified and hits the boundary" do
      errors =
        analyze_errors("""
        module M {
          fn get() -> Int {
            &nope
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0037"))
    end
  end

  describe "higher-order stdlib callbacks" do
    test "List.map rejects a wrong-arity callback" do
      errors =
        analyze_errors("""
        module M {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn run(items: List[Int]) -> List[Int] {
            List.map(items, &add)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "List.map"
             end)
    end

    test "List.map rejects a non-function callback" do
      errors =
        analyze_errors("""
        module M {
          fn run(items: List[Int]) -> List[Int] {
            List.map(items, 42)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "List.map"
             end)
    end

    test "List.filter rejects a callback that does not return Bool" do
      errors =
        analyze_errors("""
        module M {
          fn label(n: Int) -> String {
            "n"
          }

          fn run(items: List[Int]) -> List[Int] {
            List.filter(items, &label)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "List.filter"
             end)
    end

    test "List.filter accepts a Bool-returning callback" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn big(n: Int) -> Bool {
                   n > 10
                 }

                 fn run(items: List[Int]) -> List[Int] {
                   List.filter(items, &big)
                 }
               }
               """)
    end

    test "List.map derives its element type from the callback's return" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn double(n: Int) -> Int {
                   n * 2
                 }

                 fn run(items: List[Int]) -> List[Int] {
                   List.map(items, &double)
                 }
               }
               """)
    end

    test "a derived List.map element type is checked at the return boundary" do
      errors =
        analyze_errors("""
        module M {
          fn double(n: Int) -> Int {
            n * 2
          }

          fn run(items: List[Int]) -> List[String] {
            List.map(items, &double)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "List[String]"
             end)
    end

    test "List.reduce derives its return type from the callback" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(acc: Int, n: Int) -> Int {
                   acc + n
                 }

                 fn total(items: List[Int]) -> Int {
                   List.reduce(items, 0, &add)
                 }
               }
               """)
    end

    test "a derived List.reduce return type is checked at the boundary" do
      errors =
        analyze_errors("""
        module M {
          fn add(acc: Int, n: Int) -> Int {
            acc + n
          }

          fn total(items: List[Int]) -> String {
            List.reduce(items, 0, &add)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "String"
             end)
    end

    test "List.reduce rejects a wrong-arity callback" do
      errors =
        analyze_errors("""
        module M {
          fn bump(n: Int) -> Int {
            n + 1
          }

          fn total(items: List[Int]) -> Int {
            List.reduce(items, 0, &bump)
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "List.reduce"
             end)
    end
  end
end
