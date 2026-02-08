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

      assert_raise RuntimeError, ~r/Assertion failed/, fn ->
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
end
