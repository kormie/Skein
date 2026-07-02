defmodule Skein.AnalyzerUnresolvedTest do
  @moduledoc """
  B4 (#293): every unresolved reference is a structured analyzer error at the
  site itself — never a silent `:unknown` that reaches a codegen fallback and
  fails BEAM compilation with an unbound Core variable.

  Before B4, unknown `&fn` references, unknown bare calls off the boundary
  path, bare fn names used as values, and unknown store-table methods were all
  accepted by the analyzer and died in `:compile.forms/2` with
  `{:unbound_var, ...}` surfaced as a raw E0001.
  """
  use ExUnit.Case, async: true

  alias Skein.Compiler

  defp errors(source) do
    case Compiler.compile_string(source) do
      {:module, _} -> []
      {:error, errs} -> errs
    end
  end

  defp refute_bridge_failure(errs) do
    refute Enum.any?(errs, &(&1.message =~ "Core Erlang compilation failed")),
           "program reached BEAM compilation with invalid Core Erlang: #{inspect(errs)}"
  end

  describe "unknown &fn references (E0010)" do
    test "in a fn body" do
      errs =
        errors("""
        module M {
          fn f() -> Int {
            let g = &nope
            1
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "in a handler body" do
      errs =
        errors("""
        module M {
          capability http.in
          handler http GET "/x" (req) -> {
            let g = &nope
            respond.json(200, "ok")
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "in an agent handler body" do
      errs =
        errors("""
        agent A {
          capability memory.kv
          state { n: Int }
          on start(order_id: String) -> {
            let g = &nope
            memory.put("k", "v")
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "in a test body" do
      errs =
        errors("""
        module M {
          fn f() -> Int { 1 }
          test "t" {
            let g = &nope
            assert true
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "passed to process.spawn" do
      errs =
        errors("""
        module M {
          capability process.spawn
          fn go() -> String {
            process.spawn("t", &nope)!
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "in a scenario provider body" do
      errs =
        errors("""
        module M {
          capability tool.use(Ids.New)
          capability uuid

          tool Ids.New {
            input { kind: String }
            output { id: Uuid }
            implement { Ok({ id: uuid.new() }) }
          }

          scenario "s" {
            capability tool.use(Ids.New) {
              capability uuid {
                implement() -> Uuid {
                  let g = &nope
                  Uuid.parse("00000000-0000-4000-8000-000000000001")!
                }
              }
            }
            expect {
              let r = tool.call(Ids.New, { kind: "x" })!
              assert true
            }
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "nope" end)
    end

    test "a &ref to a declared fn stays clean" do
      assert {:module, _} =
               Compiler.compile_string("""
               module M {
                 fn incr(n: Int) -> Int { n + 1 }
                 fn f() -> List[Int] {
                   List.map([1, 2], &incr)
                 }
               }
               """)
    end
  end

  describe "unknown bare calls (E0010)" do
    test "off the boundary path (discarded let)" do
      errs =
        errors("""
        module M {
          fn f() -> Int {
            let _x = mystery()
            1
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "mystery" end)
    end

    test "in a handler body" do
      errs =
        errors("""
        module M {
          capability http.in
          handler http GET "/x" (req) -> {
            let _x = mystery()
            respond.json(200, "ok")
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.message =~ "mystery" end)
    end

    test "suggests a declared fn for a typo" do
      errs =
        errors("""
        module M {
          fn greet(name: String) -> String { name }
          fn f() -> Int {
            let _x = gret("a")
            1
          }
        }
        """)

      assert Enum.any?(errs, fn e -> e.code == "E0010" and e.fix_code =~ "greet" end)
    end
  end

  describe "bare fn names as values (E0020)" do
    test "a fn name without & is rejected with the &name fix" do
      errs =
        errors("""
        module M {
          fn a() -> Int { 1 }
          fn f() -> Int {
            let _x = a
            1
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.fix_code == "&a" end)
    end
  end

  describe "calling variables" do
    test "a call through a fn-typed variable types as the fn's return" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module M {
                 fn one() -> Int { 1 }
                 fn f() -> Int {
                   let g = &one
                   g()
                 }
               }
               """)

      assert mod.f() == 1
    end

    test "wrong argument arity through a fn-typed variable is E0020" do
      errs =
        errors("""
        module M {
          fn one() -> Int { 1 }
          fn f() -> Int {
            let g = &one
            g(5)
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "argument" end)
    end

    test "calling a non-function variable is E0020" do
      errs =
        errors("""
        module M {
          fn f() -> Int {
            let n = 42
            n()
          }
        }
        """)

      refute_bridge_failure(errs)
      assert Enum.any?(errs, fn e -> e.code == "E0020" and e.message =~ "n" end)
    end
  end

  describe "unknown store-table methods (E0010)" do
    test "store.<table>.<unknown>() is rejected with the method list" do
      errs =
        errors("""
        module M {
          capability store
          fn f() -> Int {
            let _x = store.users.frobnicate("k")
            1
          }
        }
        """)

      refute_bridge_failure(errs)

      assert Enum.any?(errs, fn e ->
               e.code == "E0010" and e.message =~ "frobnicate" and e.message =~ "store"
             end)
    end
  end
end
