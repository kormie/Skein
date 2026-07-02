defmodule Skein.AnalyzerWritabilityDiagnosticsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Diagnostic-quality regressions found by the agent-writability benchmark
  (#336): the natural wrong guesses (`Some(...)`/`None` in construction,
  `input.<field>` in a tool implement body) must get hints that teach the
  actual language model, and must never carry a machine-applicable fix
  that makes the program worse.
  """

  defp check!(source) do
    {:ok, %{errors: errors}} = Skein.Compiler.check_string(source)
    errors
  end

  describe "Some/None in construction position (#336)" do
    test "Some(...) in a record literal explains the bare-inner-value rule" do
      errors =
        check!("""
        module Contacts {
          type Contact { id: String @primary, nickname: Option[String] }

          fn make() -> Contact {
            Contact { id: "a", nickname: Some("Ally") }
          }
        }
        """)

      assert [%{code: "E0010"} = error] = errors
      assert error.message =~ "Some"
      assert error.message =~ "constructor"
      assert error.fix_hint =~ "bare inner value"
      assert error.fix_hint =~ "match patterns"
      # Never a machine-applicable variant replacement (was: "Timeout").
      assert error.fix_code == nil
      assert error.edit_kind == nil
    end

    test "bare None in a record literal explains field omission" do
      errors =
        check!("""
        module Contacts {
          type Contact { id: String @primary, nickname: Option[String] }

          fn make() -> Contact {
            Contact { id: "a", nickname: None }
          }
        }
        """)

      assert [%{code: "E0010"} = error] = errors
      assert error.message =~ "None"
      assert error.fix_hint =~ "Omit"
      assert error.fix_code == nil
      assert error.edit_kind == nil
    end

    test "Some as a plain value gets the same steer" do
      errors =
        check!("""
        module M {
          fn f() -> Option[Int] { Some(1) }
        }
        """)

      assert %{code: "E0010"} = error = Enum.find(errors, &(&1.message =~ "Some"))
      assert error.fix_hint =~ "bare inner value"
      assert error.fix_code == nil
    end

    test "a user-declared Some variant still resolves normally" do
      errors =
        check!("""
        module M {
          enum Wrapped { Some(v: Int) None }

          fn f() -> Wrapped { Wrapped.Some(1) }
        }
        """)

      assert errors == []
    end
  end

  describe "unknown constructors keep useful suggestions, drop far-fetched ones (#336)" do
    test "a close misspelling still gets a machine-applicable replacement" do
      errors =
        check!("""
        module M {
          enum Status { Active -> [] }

          fn f() -> Status { Activ() }
        }
        """)

      assert %{code: "E0010"} = error = Enum.find(errors, &(&1.message =~ "Activ"))
      assert error.fix_code == "Active"
      assert error.edit_kind == :replace
    end

    test "an unknown constructor with no close variant carries no replacement fix" do
      errors =
        check!("""
        module M {
          fn f() -> Int { Frobnicate(1) }
        }
        """)

      assert %{code: "E0010"} = error = Enum.find(errors, &(&1.message =~ "Frobnicate"))
      # No declared or builtin variant is anywhere near "Frobnicate":
      # suggesting one anyway (the old max-jaro pick) is a wrong
      # machine-applicable edit.
      assert error.fix_code == nil
      assert error.edit_kind == nil
    end
  end

  describe "test-to-scenario steering (#336)" do
    test "E0029 fix_code is a Skein template with the expect wrapper" do
      errors =
        check!("""
        module M {
          capability memory.kv("m")

          fn f() -> String { memory.put("k", "v")! }

          test "t" { assert f() == "v" }
        }
        """)

      assert %{code: "E0029"} = error = Enum.find(errors, &(&1.code == "E0029"))
      assert error.fix_code == "scenario \"...\" { expect { ... } }"
      assert error.fix_hint =~ "expect"
      # `/* ... */` is not Skein comment syntax — never in fix_code (#313).
      refute error.fix_code =~ "/*"
    end

    test "a bare assert in a scenario body steers to the expect block" do
      errors =
        check!("""
        module M {
          fn f() -> Int { 1 }

          scenario "s" {
            assert f() == 1
          }
        }
        """)

      assert %{code: "E0001"} = error = Enum.find(errors, &(&1.code == "E0001"))
      assert error.fix_hint =~ "expect { assert"
      assert error.fix_code == "expect { ... }"
    end
  end

  describe "input access in tool implement bodies (#336)" do
    test "input.<field> steers to the in-scope field names" do
      errors =
        check!("""
        module Billing {
          tool Billing.ComputeTax {
            description: "d"
            input { amount: Int, rate_pct: Int }
            output { tax: Int }
            implement {
              Ok({ tax: input.amount * input.rate_pct / 100 })
            }
          }
        }
        """)

      assert [%{code: "E0010"} = error | _] = errors
      assert error.message =~ "input"
      assert error.fix_hint =~ "directly in scope"
      assert error.fix_hint =~ "amount, rate_pct"
      # No `let input = value` template — that shadows the field the
      # body is reaching for with a contextual-keyword name.
      assert error.fix_code == nil
    end

    test "an ordinary unknown 'input' outside a tool keeps the generic hint" do
      errors =
        check!("""
        module M {
          fn f() -> Int { input }
        }
        """)

      assert %{code: "E0010"} = error = Enum.find(errors, &(&1.message =~ "input"))
      assert error.fix_hint == "Did you mean to declare this variable?"
    end
  end
end
