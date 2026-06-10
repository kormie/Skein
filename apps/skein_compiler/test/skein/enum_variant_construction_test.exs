defmodule Skein.EnumVariantConstructionTest do
  @moduledoc """
  Enum variant construction in expression position (issue #96).

  Zero-field variants construct as their snake_case atom (`Status.Active`
  and bare `Active` -> `:active`), matching the pattern side. Unknown
  variants and wrong constructor arity/types are structured compile
  errors instead of codegen crashes.
  """
  use ExUnit.Case, async: true

  alias Skein.Analyzer
  alias Skein.Compiler
  alias Skein.Lexer
  alias Skein.Parser

  @status_module """
  module Statuses {
    enum Status {
      Active
      Suspended
      Banned(reason: String)
    }

  """

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  defp analyze_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:error, errors} -> errors
      {:ok, _, warnings} -> warnings
      {:ok, _} -> []
    end
  end

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  defp in_status_module(body), do: @status_module <> body <> "\n}\n"

  # ------------------------------------------------------------------
  # Analyzer: valid constructions
  # ------------------------------------------------------------------

  describe "analyzer accepts" do
    test "qualified zero-field variant construction" do
      assert {:ok, _} =
               analyze(
                 in_status_module("""
                 fn activate() -> Status { Status.Active }
                 """)
               )
    end

    test "bare zero-field variant construction" do
      assert {:ok, _} =
               analyze(
                 in_status_module("""
                 fn activate() -> Status { Active }
                 """)
               )
    end

    test "qualified data variant construction" do
      assert {:ok, _} =
               analyze(
                 in_status_module("""
                 fn ban(reason: String) -> Status { Status.Banned(reason) }
                 """)
               )
    end

    test "explicit empty-args construction of a zero-field variant" do
      assert {:ok, _} =
               analyze(
                 in_status_module("""
                 fn activate() -> Status { Status.Active() }
                 """)
               )
    end
  end

  # ------------------------------------------------------------------
  # Analyzer: structured errors
  # ------------------------------------------------------------------

  describe "analyzer errors" do
    test "unknown variant in qualified reference is E0010 with closest-name fix" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Status.Actve }
          """)
        )

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error
      assert error.message =~ "Actve"
      assert error.fix_hint =~ "Active"
      assert error.fix_code =~ "Active"
    end

    test "unknown variant in qualified call is E0010" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Status.Nope("x") }
          """)
        )

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error
      assert error.message =~ "Nope"
    end

    test "data variant referenced without arguments is a structured error" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Status.Banned }
          """)
        )

      error = Enum.find(errors, &(&1.code == "E0020"))
      assert error
      assert error.message =~ "Banned"
      assert error.fix_code =~ "Banned("
    end

    test "wrong constructor arity is E0020" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Status.Banned("spam", "extra") }
          """)
        )

      error = Enum.find(errors, &(&1.code == "E0020"))
      assert error
      assert error.message =~ "Banned"
      assert error.message =~ "1"
    end

    test "wrong constructor argument type is E0020" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Status.Banned(42) }
          """)
        )

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Banned"
             end)
    end

    test "bare unknown uppercase identifier is E0010, not a codegen crash" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Actve }
          """)
        )

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error
      assert error.message =~ "Actve"
      assert error.fix_code =~ "Active"
    end

    test "bare unknown constructor call is E0010" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Nope("x") }
          """)
        )

      assert Enum.any?(errors, &(&1.code == "E0010"))
    end

    test "bare constructor call with wrong arity is E0020" do
      errors =
        analyze_errors(
          in_status_module("""
          fn oops() -> Status { Banned("spam", "extra") }
          """)
        )

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end
  end

  # ------------------------------------------------------------------
  # Integration: construction round-trips through match at runtime
  # ------------------------------------------------------------------

  describe "runtime round-trip" do
    test "zero-field and data variants round-trip through match" do
      mod =
        compile!(
          in_status_module("""
          fn make_active() -> Status { Status.Active }
          fn make_suspended() -> Status { Suspended }
          fn make_banned(reason: String) -> Status { Status.Banned(reason) }

          fn describe(s: Status) -> String {
            match s {
              Active -> "active"
              Suspended -> "suspended"
              Banned(reason) -> reason
            }
          }
          """)
        )

      assert mod.describe(mod.make_active()) == "active"
      assert mod.describe(mod.make_suspended()) == "suspended"
      assert mod.describe(mod.make_banned("spam")) == "spam"
    end

    test "zero-field variants lower to the same atom as patterns" do
      mod =
        compile!(
          in_status_module("""
          fn make_active() -> Status { Status.Active }
          fn make_active_call() -> Status { Status.Active() }
          """)
        )

      assert mod.make_active() == :active
      assert mod.make_active_call() == :active
    end

    test "data variants lower to tagged tuples" do
      mod =
        compile!(
          in_status_module("""
          fn make_banned() -> Status { Status.Banned("spam") }
          """)
        )

      assert mod.make_banned() == {:banned, "spam"}
    end

    test "multi-word variant names snake_case consistently" do
      mod =
        compile!("""
        module Events {
          enum Event {
            ChargeSucceeded
            DisputeCreated(id: String)
          }

          fn make_charge() -> Event { Event.ChargeSucceeded }

          fn describe(e: Event) -> String {
            match e {
              ChargeSucceeded -> "charged"
              DisputeCreated(id) -> id
            }
          }
        }
        """)

      assert mod.make_charge() == :charge_succeeded
      assert mod.describe(mod.make_charge()) == "charged"
    end
  end
end
