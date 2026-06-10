defmodule Skein.AssertFailureTest do
  @moduledoc """
  Structured assertion failures (issue #105): a failing `assert` raises
  `Skein.Runtime.AssertionError` carrying the operands, the rendered
  expression, and the assert's file:line — instead of a bare
  "Assertion failed" RuntimeError.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler
  alias Skein.Runtime.AssertionError

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  defp assertion_error!(mod, test_fn) do
    try do
      apply(mod, test_fn, [])
      flunk("expected the test to fail")
    rescue
      e in AssertionError -> e
    end
  end

  test "failing == assert carries operands, expression, and location" do
    mod =
      compile!("""
      module AssertEq {
        fn hello(name: String) -> String {
          "Goodbye, ${name}!"
        }

        test "hello returns greeting" {
          assert hello("World") == "Hello, World!"
        }
      }
      """)

    error = assertion_error!(mod, :__test_0__)

    assert error.op == :==
    assert error.left == "Goodbye, World!"
    assert error.right == "Hello, World!"
    assert error.line == 7
    assert is_binary(error.expr)
    assert error.expr =~ "hello"

    message = Exception.message(error)
    assert message =~ ~s(left:  "Goodbye, World!")
    assert message =~ ~s(right: "Hello, World!")
  end

  test "other comparison operators report both operands" do
    mod =
      compile!("""
      module AssertLt {
        test "ordering" {
          assert 10 < 5
        }
      }
      """)

    error = assertion_error!(mod, :__test_0__)
    assert error.op == :<
    assert error.left == 10
    assert error.right == 5
  end

  test "bare truthy assert reports location without operands" do
    mod =
      compile!("""
      module AssertBare {
        fn truthy() -> Bool {
          false
        }

        test "bare" {
          assert truthy()
        }
      }
      """)

    error = assertion_error!(mod, :__test_0__)
    assert error.op == nil
    assert error.left == nil
    assert error.line == 7
    assert Exception.message(error) =~ "Assertion failed"
  end

  test "passing asserts still return :ok" do
    mod =
      compile!("""
      module AssertPass {
        test "passes" {
          assert 1 == 1
          assert 2 > 1
        }
      }
      """)

    assert mod.__test_0__() == :ok
  end

  test "assert on a != comparison reports operands" do
    mod =
      compile!("""
      module AssertNeq {
        test "neq" {
          assert "same" != "same"
        }
      }
      """)

    error = assertion_error!(mod, :__test_0__)
    assert error.op == :!=
    assert error.left == "same"
    assert error.right == "same"
  end
end
