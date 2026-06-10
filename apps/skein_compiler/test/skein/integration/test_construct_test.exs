defmodule Skein.Integration.TestConstructTest do
  @moduledoc """
  End-to-end integration tests for Phase 7: test construct compilation.

  These tests compile Skein source code with `test` declarations through
  the full pipeline and verify the resulting modules expose test metadata
  and executable test functions.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # ------------------------------------------------------------------
  # Test metadata
  # ------------------------------------------------------------------

  describe "test declaration → __tests__/0 metadata" do
    test "module with one test exports test metadata" do
      mod =
        compile!("""
        module TestBasic {
          fn add(a: Int, b: Int) -> Int { a + b }

          test "add returns correct sum" {
            assert add(2, 3) == 5
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 1
      assert %{description: "add returns correct sum", fn: :__test_0__} = hd(tests)
    end

    test "module with multiple tests exports all metadata" do
      mod =
        compile!("""
        module TestMulti {
          fn double(x: Int) -> Int { x * 2 }

          test "double of 1" {
            assert double(1) == 2
          }

          test "double of 0" {
            assert double(0) == 0
          }

          test "double of negative" {
            assert double(0 - 5) == 0 - 10
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 3
      descriptions = Enum.map(tests, & &1.description)
      assert "double of 1" in descriptions
      assert "double of 0" in descriptions
      assert "double of negative" in descriptions
    end

    test "module with no tests returns empty list" do
      mod =
        compile!("""
        module TestNone {
          fn add(a: Int, b: Int) -> Int { a + b }
        }
        """)

      assert mod.__tests__() == []
    end
  end

  # ------------------------------------------------------------------
  # Test execution
  # ------------------------------------------------------------------

  describe "test function execution" do
    test "passing test returns :ok" do
      mod =
        compile!("""
        module TestPass {
          fn add(a: Int, b: Int) -> Int { a + b }

          test "add works" {
            assert add(2, 3) == 5
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end

    test "failing assertion raises an error" do
      mod =
        compile!("""
        module TestFail {
          fn add(a: Int, b: Int) -> Int { a + b }

          test "add wrong" {
            assert add(2, 3) == 99
          }
        }
        """)

      assert_raise Skein.Runtime.AssertionError, ~r/Assertion failed/, fn ->
        mod.__test_0__()
      end
    end

    test "test with multiple passing assertions" do
      mod =
        compile!("""
        module TestMultiAssert {
          fn double(x: Int) -> Int { x * 2 }

          test "double various" {
            assert double(1) == 2
            assert double(0) == 0
            assert double(3) == 6
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end

    test "test can call module functions" do
      mod =
        compile!("""
        module TestCallFns {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          fn add(a: Int, b: Int) -> Int { a + b }

          test "greet and add" {
            assert add(1, 2) == 3
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end
  end

  # ------------------------------------------------------------------
  # Scenario tests (Phase 8a)
  # ------------------------------------------------------------------

  describe "scenario declaration → compilation and execution" do
    test "scenario with given bindings and passing assertions" do
      mod =
        compile!("""
        module ScenarioBasic {
          fn add(a: Int, b: Int) -> Int { a + b }

          scenario "addition works with given values" {
            given {
              x: 10
              y: 20
            }

            expect {
              assert add(x, y) == 30
            }
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 1
      assert %{description: "addition works with given values"} = hd(tests)

      # Execute the scenario test
      assert mod.__test_0__() == :ok
    end

    test "scenario with failing assertion raises error" do
      mod =
        compile!("""
        module ScenarioFail {
          scenario "fails" {
            given {
              x: 1
            }

            expect {
              assert x == 999
            }
          }
        }
        """)

      assert_raise Skein.Runtime.AssertionError, ~r/Assertion failed/, fn ->
        mod.__test_0__()
      end
    end

    test "scenario with multiple given bindings all accessible in expect" do
      mod =
        compile!("""
        module ScenarioMulti {
          fn multiply(a: Int, b: Int) -> Int { a * b }

          scenario "multi bindings" {
            given {
              a: 3
              b: 7
            }

            expect {
              assert multiply(a, b) == 21
              assert a + b == 10
            }
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end

    test "scenario mixed with regular tests" do
      mod =
        compile!("""
        module ScenarioMixed {
          fn double(x: Int) -> Int { x * 2 }

          test "basic double" {
            assert double(5) == 10
          }

          scenario "double with given" {
            given {
              n: 7
            }

            expect {
              assert double(n) == 14
            }
          }

          test "another double" {
            assert double(0) == 0
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 3
      assert Enum.at(tests, 0).description == "basic double"
      assert Enum.at(tests, 1).description == "double with given"
      assert Enum.at(tests, 2).description == "another double"

      # All tests should pass
      assert mod.__test_0__() == :ok
      assert mod.__test_1__() == :ok
      assert mod.__test_2__() == :ok
    end

    test "scenario with string given values" do
      mod =
        compile!("""
        module ScenarioStrings {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          scenario "greeting scenario" {
            given {
              who: "World"
            }

            expect {
              assert greet(who) == "Hello, World!"
            }
          }
        }
        """)

      assert mod.__test_0__() == :ok
    end
  end

  # ------------------------------------------------------------------
  # Golden tests (Phase 8a)
  # ------------------------------------------------------------------

  describe "golden declaration → compilation and execution" do
    @tmp_dir Path.expand("../../tmp/golden_test", __DIR__)

    setup do
      File.mkdir_p!(@tmp_dir)
      on_exit(fn -> File.rm_rf!(@tmp_dir) end)
      %{tmp_dir: @tmp_dir}
    end

    test "golden test compiles and runs assertions", %{tmp_dir: tmp_dir} do
      trace_path = Path.join(tmp_dir, "test_trace.json")

      File.write!(
        trace_path,
        Jason.encode!([
          %{kind: "handler", method: "get", path: "/hello", status: 200, duration_us: 150}
        ])
      )

      mod =
        compile!("""
        module GoldenBasic {
          golden "simple trace" from trace "#{trace_path}" {
            assert true
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 1
      assert %{description: "simple trace"} = hd(tests)

      # Execute the golden test
      assert mod.__test_0__() == :ok
    end

    test "golden test with failing assertion", %{tmp_dir: tmp_dir} do
      trace_path = Path.join(tmp_dir, "test_trace2.json")
      File.write!(trace_path, "[]")

      mod =
        compile!("""
        module GoldenFail {
          golden "failing trace" from trace "#{trace_path}" {
            assert false
          }
        }
        """)

      assert_raise Skein.Runtime.AssertionError, ~r/Assertion failed/, fn ->
        mod.__test_0__()
      end
    end

    test "golden mixed with tests and scenarios", %{tmp_dir: tmp_dir} do
      trace_path = Path.join(tmp_dir, "test_trace3.json")
      File.write!(trace_path, "[]")

      mod =
        compile!("""
        module GoldenMixed {
          fn ok() -> Bool { true }

          test "basic" { assert ok() }

          scenario "scenario" {
            given { x: 1 }
            expect { assert x == 1 }
          }

          golden "trace" from trace "#{trace_path}" {
            assert ok()
          }
        }
        """)

      tests = mod.__tests__()
      assert length(tests) == 3
      assert Enum.at(tests, 0).description == "basic"
      assert Enum.at(tests, 1).description == "scenario"
      assert Enum.at(tests, 2).description == "trace"

      assert mod.__test_0__() == :ok
      assert mod.__test_1__() == :ok
      assert mod.__test_2__() == :ok
    end
  end
end
