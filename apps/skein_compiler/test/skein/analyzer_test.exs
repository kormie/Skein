defmodule Skein.AnalyzerTest do
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  # Helper: lex, parse, then analyze
  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)
    Analyzer.analyze(ast)
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  # ------------------------------------------------------------------
  # Valid programs should pass analysis
  # ------------------------------------------------------------------

  describe "valid programs" do
    test "simple function with correct types" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn greet(name: String) -> String {
                   "Hello, ${name}!"
                 }
               }
               """)
    end

    test "arithmetic with Int types" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int {
                   a + b
                 }
               }
               """)
    end

    test "comparison returns Bool" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn is_positive(n: Int) -> Bool {
                   n > 0
                 }
               }
               """)
    end

    test "match expression with consistent arm types" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn classify(n: Int) -> String {
                   match n > 0 {
                     true  -> "positive"
                     false -> "non-positive"
                   }
                 }
               }
               """)
    end

    test "let binding with inferred type" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn double(x: Int) -> Int {
                   let result = x + x
                   result
                 }
               }
               """)
    end

    test "multiple functions" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int { a + b }
                 fn greet(name: String) -> String { "Hi, ${name}!" }
               }
               """)
    end

    test "boolean logic" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn both(a: Bool, b: Bool) -> Bool {
                   a && b
                 }
               }
               """)
    end

    test "function with type declarations" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   name: String
                   age: Int
                 }

                 fn greet(name: String) -> String {
                   "hello"
                 }
               }
               """)
    end

    test "function with enum declarations" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Status {
                   Active
                   Inactive
                 }

                 fn check() -> Bool {
                   true
                 }
               }
               """)
    end

    test "match on wildcard is always exhaustive" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn describe(n: Int) -> String {
                   match n {
                     0 -> "zero"
                     _ -> "other"
                   }
                 }
               }
               """)
    end

    test "float arithmetic" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add_floats(a: Float, b: Float) -> Float {
                   a + b
                 }
               }
               """)
    end

    test "function calling another function" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn double(x: Int) -> Int { x + x }
                 fn quadruple(x: Int) -> Int {
                   double(double(x))
                 }
               }
               """)
    end

    test "negation of bool" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn negate(b: Bool) -> Bool {
                   !b
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Type mismatch errors
  # ------------------------------------------------------------------

  describe "type mismatch errors" do
    test "return type mismatch: Int body, String declared" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            42
          }
        }
        """)

      assert length(errors) >= 1
      error = hd(errors)
      assert error.code == "E0020"
      assert error.severity == :error
      assert error.message =~ "type mismatch"
    end

    test "return type mismatch: String body, Int declared" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            "hello"
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0020"
    end

    test "return type mismatch: Bool body, Int declared" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            true
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0020"
    end

    test "arithmetic with String operand" do
      errors =
        analyze_errors("""
        module M {
          fn bad(s: String) -> Int {
            s + 1
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0021"
    end

    test "comparison with mismatched types" do
      errors =
        analyze_errors("""
        module M {
          fn bad(s: String) -> Bool {
            s > 0
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0021"
    end

    test "logical AND with non-Bool operand" do
      errors =
        analyze_errors("""
        module M {
          fn bad(n: Int) -> Bool {
            n && true
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0021"
    end

    test "negation of non-Bool" do
      errors =
        analyze_errors("""
        module M {
          fn bad(n: Int) -> Bool {
            !n
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0021"
    end
  end

  # ------------------------------------------------------------------
  # Match exhaustiveness
  # ------------------------------------------------------------------

  describe "match exhaustiveness" do
    test "boolean match missing false arm warns" do
      errors =
        analyze_errors("""
        module M {
          fn bad(b: Bool) -> String {
            match b {
              true -> "yes"
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0024" and e.severity == :warning
             end)
    end

    test "boolean match missing true arm warns" do
      errors =
        analyze_errors("""
        module M {
          fn bad(b: Bool) -> String {
            match b {
              false -> "no"
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0024" and e.severity == :warning
             end)
    end

    test "boolean match with both arms is exhaustive" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good(b: Bool) -> String {
                   match b {
                     true -> "yes"
                     false -> "no"
                   }
                 }
               }
               """)
    end

    test "match with wildcard is always exhaustive" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good(n: Int) -> String {
                   match n {
                     0 -> "zero"
                     _ -> "other"
                   }
                 }
               }
               """)
    end

    test "match arms with inconsistent types produces error" do
      errors =
        analyze_errors("""
        module M {
          fn bad(b: Bool) -> String {
            match b {
              true -> "yes"
              false -> 42
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e -> e.code == "E0020" end)
    end
  end

  # ------------------------------------------------------------------
  # Unknown identifiers
  # ------------------------------------------------------------------

  describe "unknown identifiers" do
    test "unknown variable reference" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            unknown_var
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0010"
    end

    test "let-bound variable is in scope" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good() -> Int {
                   let x = 42
                   x
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Unknown type references
  # ------------------------------------------------------------------

  describe "unknown type references" do
    test "function with unknown parameter type" do
      errors =
        analyze_errors("""
        module M {
          fn bad(x: Foo) -> Int {
            42
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0011"
    end

    test "function with unknown return type" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Foo {
            42
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0011"
    end

    test "user-declared type is valid in function signatures" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type Foo {
                   value: Int
                 }

                 fn make_foo() -> Foo {
                   42
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Constraint annotation validation
  # ------------------------------------------------------------------

  describe "constraint annotation validation" do
    test "@min on non-numeric type produces error" do
      errors =
        analyze_errors("""
        module M {
          type Bad {
            name: String @min(0)
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0025"
    end

    test "@max on non-numeric type produces error" do
      errors =
        analyze_errors("""
        module M {
          type Bad {
            name: String @max(100)
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0025"
    end

    test "@one_of on non-String type produces error" do
      errors =
        analyze_errors("""
        module M {
          type Bad {
            count: Int @one_of(["a", "b"])
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0025"
    end

    test "valid constraint annotations pass" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type Money {
                   amount: Int @min(0) @max(1000000)
                   currency: String @one_of(["USD", "EUR", "GBP"])
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # ! and ? operator validation
  # ------------------------------------------------------------------

  describe "! operator validation" do
    test "! on function call is accepted (no type info to verify at call site)" do
      # The ! operator on a call site can't be fully validated without knowing
      # the callee's return type - which for external/unresolved calls we skip.
      # This tests that the analyzer doesn't crash on ! usage.
      assert {:ok, _} =
               analyze("""
               module M {
                 fn wrapper() -> Int {
                   get_value()!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Function call arity checking
  # ------------------------------------------------------------------

  describe "function call arity" do
    test "calling function with wrong arity produces error" do
      errors =
        analyze_errors("""
        module M {
          fn add(a: Int, b: Int) -> Int { a + b }
          fn bad() -> Int {
            add(1)
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0012"
    end

    test "calling function with correct arity passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int { a + b }
                 fn good() -> Int {
                   add(1, 2)
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Error structure
  # ------------------------------------------------------------------

  describe "error structure" do
    test "errors have required fields for JSON serialization" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            42
          }
        }
        """)

      error = hd(errors)
      assert is_binary(error.code)
      assert error.severity in [:error, :warning]
      assert is_binary(error.message)
      assert is_map(error.location)
      assert is_integer(error.location.line)
      assert is_integer(error.location.col)
    end

    test "errors serialize to JSON" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            42
          }
        }
        """)

      error = hd(errors)
      json = Skein.Error.to_json(error)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["code"] == "E0020"
    end
  end
end
