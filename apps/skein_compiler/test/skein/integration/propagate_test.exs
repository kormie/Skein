defmodule Skein.Integration.PropagateTest do
  @moduledoc """
  Runtime semantics of the `?` (propagate) operator (#290 / B1).

  On `Err`, `expr?` exits the ENCLOSING body immediately, returning the `Err`
  tuple — it must never bind `{:error, e}` where a success value was expected
  and keep executing. Proven from compiled BEAM modules in every expression
  position: lets, arguments, match subjects/arms, nested blocks, chained
  effects, tool implement bodies, and module handlers.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Compiler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} ->
        mod

      {:error, errors} ->
        flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # A canary that raises if evaluated: `Err(..)!` lowers to erlang:error/1.
  # Any test whose Err path reaches the canary blows up instead of returning.

  describe "? early-returns from a fn on Err" do
    test "in a let binding — following statements never execute" do
      mod =
        compile!("""
        module PropLet {
          fn bump(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            let canary = Err("must never evaluate")!
            Ok(n + 1)
          }
        }
        """)

      assert {:error, reason} = mod.bump("not a number")
      assert reason == elem(Skein.Runtime.Stdlib.Int.parse("not a number"), 1)
    end

    test "the Ok path still executes the rest of the body" do
      mod =
        compile!("""
        module PropLetOk {
          fn bump(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            Ok(n + 1)
          }
        }
        """)

      assert {:ok, 42} = mod.bump("41")
      assert {:error, _} = mod.bump("nope")
    end

    test "in argument position" do
      mod =
        compile!("""
        module PropArg {
          fn double_it(s: String) -> Result[Int, String] {
            Ok(Int.parse(s)? * 2)
          }
        }
        """)

      assert {:ok, 42} = mod.double_it("21")
      assert {:error, _} = mod.double_it("x")
    end

    test "in a match subject" do
      mod =
        compile!("""
        module PropMatchSubject {
          fn classify(s: String) -> Result[String, String] {
            match Int.parse(s)? > 10 {
              true -> Ok("big")
              false -> Ok("small")
            }
          }
        }
        """)

      assert {:ok, "big"} = mod.classify("11")
      assert {:ok, "small"} = mod.classify("3")
      assert {:error, _} = mod.classify("zzz")
    end

    test "in a nested block (match arm body)" do
      mod =
        compile!("""
        module PropNested {
          fn pick(s: String, use_parse: Bool) -> Result[Int, String] {
            match use_parse {
              true -> {
                let n = Int.parse(s)?
                Ok(n * 2)
              }
              false -> Ok(0)
            }
          }
        }
        """)

      assert {:ok, 42} = mod.pick("21", true)
      assert {:ok, 0} = mod.pick("x", false)
      assert {:error, _} = mod.pick("x", true)
    end

    test "chained ? stops at the FIRST Err" do
      mod =
        compile!("""
        module PropChain {
          fn sum(a: String, b: String) -> Result[Int, String] {
            let x = Int.parse(a)?
            let y = Int.parse(b)?
            Ok(x + y)
          }
        }
        """)

      assert {:ok, 7} = mod.sum("3", "4")
      assert {:error, _} = mod.sum("x", "4")
      assert {:error, _} = mod.sum("3", "y")
    end

    test "a propagated Err from a callee does not tunnel through the caller's frame" do
      # inner's ? exits INNER only; outer sees the Err as an ordinary value
      # and handles it — outer's match must still run.
      mod =
        compile!("""
        module PropScoped {
          fn inner(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            Ok(n)
          }

          fn outer(s: String) -> String {
            match inner(s) {
              Ok(n) -> "parsed"
              Err(e) -> "handled"
            }
          }
        }
        """)

      assert mod.outer("1") == "parsed"
      assert mod.outer("x") == "handled"
    end

    property "? on Err never executes a following statement" do
      mod =
        compile!("""
        module PropNever {
          fn run(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            let canary = Err("executed past a failed ?")!
            Ok(n)
          }
        }
        """)

      check all(text <- StreamData.string([?a..?z], min_length: 1)) do
        assert {:error, _} = mod.run(text)
      end
    end
  end

  describe "? in tool implement bodies" do
    test "early-returns the Err as the tool result" do
      mod =
        compile!("""
        module PropTool {
          tool PropTool.Parse {
            input { s: String }
            output { n: Int }
            errors { ParseFailed }
            implement {
              let n = Int.parse(s)?
              Ok({ n: n })
            }
          }
        }
        """)

      assert {:ok, %{n: 7}} = mod.__tool_impl_0__(%{s: "7"})
      assert {:error, _} = mod.__tool_impl_0__(%{s: "seven"})
    end
  end

  describe "? in test and scenario bodies" do
    test "a propagated Err FAILS the test instead of silently passing" do
      # __test_N__ returns :ok on pass and only fails by raising — an
      # early-returned Err would read as a pass, so the boundary re-raises.
      mod =
        compile!("""
        module PropTestBody {
          fn parse(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            Ok(n)
          }

          test "propagates" {
            let n = parse("not a number")?
            assert n == 1
          }
        }
        """)

      assert_raise ErlangError, ~r/unhandled_propagated_err/, fn ->
        mod.__test_0__()
      end
    end

    test "a passing ? in a test body still returns :ok" do
      mod =
        compile!("""
        module PropTestBodyOk {
          fn parse(s: String) -> Result[Int, String] {
            let n = Int.parse(s)?
            Ok(n)
          }

          test "propagates ok" {
            let n = parse("41")?
            assert n == 41
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end
  end

  describe "? in module handlers" do
    test "early-returns the Err instead of responding with a bound error tuple" do
      mod =
        compile!("""
        module PropHandler {
          capability http.in

          type Item {
            name: String
          }

          handler http POST "/items" (req) -> {
            let item = req.json[Item]?
            respond.json(201, item)
          }
        }
        """)

      # Ok path: handler runs to the respond tuple.
      ok_req = %{body: ~s({"name":"Widget"})}
      refute match?({:error, _}, mod.__handler_0__(ok_req))

      # Err path: req.json fails to decode; the handler must exit with the
      # Err — previously it bound item = {:error, e} and kept executing.
      assert {:error, _} = mod.__handler_0__(%{body: "not json"})
    end
  end
end
