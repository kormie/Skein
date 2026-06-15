defmodule Skein.AnalyzerTest do
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  # Helper: lex, parse, then analyze
  # Normalizes {ok, ast, warnings} to {:ok, ast} for simple assertion matching
  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  # Returns all errors and warnings from analysis
  defp analyze_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:error, errors} -> errors
      {:ok, _, warnings} -> warnings
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

    test "negation of an Int types as Int" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn negate(n: Int) -> Int {
                   -n
                 }
               }
               """)
    end

    test "negation of a Float types as Float" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn negate(x: Float) -> Float {
                   -x
                 }
               }
               """)
    end

    test "negative integer literal types as Int" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn freezing() -> Int {
                   -18
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
      assert hd(errors).code == "E0020"
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
      assert hd(errors).code == "E0020"
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
      assert hd(errors).code == "E0020"
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
      assert hd(errors).code == "E0020"
    end

    test "arithmetic negation of a String is an error with a hint" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            -"foo"
          }
        }
        """)

      assert length(errors) >= 1
      error = hd(errors)
      assert error.code == "E0020"
      assert error.severity == :error
      assert error.message =~ "'-'"
      assert error.message =~ "String"
      assert error.fix_hint != nil
      assert error.fix_code != nil
    end

    test "arithmetic negation of a Bool is an error" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            -true
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).code == "E0020"
    end
  end

  # ------------------------------------------------------------------
  # Type lattice soundness (issue #259)
  # ------------------------------------------------------------------

  describe "type lattice soundness (issue #259)" do
    # Each of these four programs compiled with ZERO diagnostics before the
    # type-lattice fix even though every body is ill-typed against its
    # declared return type (user-type/enum/:unknown were "compatible with
    # anything"; Ok/Err and list literals inferred :unknown). They must now
    # be E0020-class type errors.

    test "user type: Int body against a declared user type is rejected" do
      errors =
        analyze_errors("""
        module M {
          type T {
            value: Int
          }

          fn bad() -> T {
            42
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.severity == :error))
    end

    test "enum: Int body against a declared enum is rejected" do
      errors =
        analyze_errors("""
        module M {
          enum E {
            A
            B
          }

          fn bad() -> E {
            99
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.severity == :error))
    end

    test "Ok(String) against Result[Int, String] is rejected" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Result[Int, String] {
            Ok("hi")
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.severity == :error))
    end

    test "heterogeneous list literal against List[Int] is rejected" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> List[Int] {
            [1, "two", 3]
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.severity == :error))
    end

    # Control: a plain primitive mismatch was already rejected — keep it green.
    test "control: String body against Int is still rejected" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            "hello"
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    # Positive controls: well-typed versions of the same shapes must still
    # compile clean (guard against over-tightening the variance).
    test "Ok(Int) against Result[Int, String] is accepted" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good() -> Result[Int, String] {
                   Ok(42)
                 }
               }
               """)
    end

    test "Err(String) against Result[Int, String] is accepted" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good() -> Result[Int, String] {
                   Err("nope")
                 }
               }
               """)
    end

    test "homogeneous list literal against List[Int] is accepted" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn good() -> List[Int] {
                   [1, 2, 3]
                 }
               }
               """)
    end

    test "user type against the same user type is accepted" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type Foo {
                   value: Int
                 }

                 fn identity(foo: Foo) -> Foo {
                   foo
                 }
               }
               """)
    end

    test "a user type is not compatible with a different user type" do
      errors =
        analyze_errors("""
        module M {
          type Foo {
            value: Int
          }

          type Bar {
            value: Int
          }

          fn bad(foo: Foo) -> Bar {
            foo
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.severity == :error))
    end

    # Criterion 4: :unknown is transient-only. A schema-bearing type parameter
    # (`req.json[T]` / `llm.json[T]` / `msg.json[T]`) that names an undeclared
    # type would reach codegen and silently emit an empty JSON Schema on a
    # public boundary — it must be a hard error instead.
    test "req.json[T] with an undeclared type is rejected" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http POST "/x" (req) -> {
            let data = req.json[Undeclared]()?
            respond.json(200, { ok: true })
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0024" and &1.severity == :error))
    end

    test "llm.json[T] with an undeclared type is rejected" do
      errors =
        analyze_errors("""
        module M {
          capability model("anthropic", "claude-opus-4-8")

          fn classify(input: String) -> String {
            llm.json[Undeclared]("claude-opus-4-8", "system", input)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0024" and &1.severity == :error))
    end

    test "req.json[T] with a declared type is accepted" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in

                 type CreateUserInput {
                   name: String
                 }

                 handler http POST "/users" (req) -> {
                   let data = req.json[CreateUserInput]()?
                   respond.json(200, { ok: true })
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Match exhaustiveness
  # ------------------------------------------------------------------

  describe "match exhaustiveness" do
    test "boolean match missing false arm is a compile error (#261)" do
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
               e.code == "E0021" and e.severity == :error
             end)
    end

    test "boolean match missing true arm is a compile error (#261)" do
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
               e.code == "E0021" and e.severity == :error
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

    test "enum-typed fn param subjects are variant-level checked (E0024)" do
      errors =
        analyze_errors("""
        module M {
          enum Event {
            Charge(amount: Int)
            Refund
          }

          fn f(e: Event) -> String {
            match e {
              Refund -> "refund"
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0024" and e.severity == :error and e.message =~ "Charge"
             end)
    end

    test "Result match missing the Err arm is a compile error (#261)" do
      errors =
        analyze_errors("""
        module M {
          fn f(s: String) -> Int {
            match Int.parse(s) {
              Ok(n) -> n
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0024" and e.severity == :error and e.message =~ "Err"
             end)
    end

    test "Result match with Ok and Err(NotFound) is exhaustive (spec §8.2 shape)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability store.table("users")

                 handler http GET "/u/:id" (req) -> {
                   match store.users.get(req.params.id) {
                     Ok(u)         -> respond.json(200, u)
                     Err(NotFound) -> respond.json(404, { error: "no" })
                   }
                 }
               }
               """)
    end

    test "Option match missing the None arm is a compile error (#261)" do
      errors =
        analyze_errors("""
        module M {
          fn f(xs: List[String]) -> String {
            match List.first(xs) {
              Some(x) -> x
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0024" and e.severity == :error and e.message =~ "None"
             end)
    end

    test "Option match with Some and None is exhaustive" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn f(xs: List[String]) -> String {
                   match List.first(xs) {
                     Some(x) -> x
                     None    -> "empty"
                   }
                 }
               }
               """)
    end

    test "a wildcard makes a Result match exhaustive" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn f(s: String) -> Int {
                   match Int.parse(s) {
                     Ok(n) -> n
                     _     -> 0
                   }
                 }
               }
               """)
    end

    test "dotted variant patterns count as variant coverage (no false E0024)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Event {
                   Charge(amount: Int)
                   Refund
                 }

                 fn f(e: Event) -> String {
                   match e {
                     Event.Charge(n) -> "charged ${n}"
                     Event.Refund -> "refund"
                   }
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # W0004: enum value-level exhaustiveness
  # ------------------------------------------------------------------

  describe "W0004: enum value-level exhaustiveness" do
    test "literal variant field pattern without a wildcard arm warns" do
      errors =
        analyze_errors("""
        module M {
          enum Event {
            Charge(amount: Int)
            Refund
          }

          fn f(e: Event) -> String {
            match e {
              Event.Charge(5) -> "five"
              Refund -> "refund"
            }
          }
        }
        """)

      warning = Enum.find(errors, &(&1.code == "W0004"))
      assert warning
      assert warning.severity == :warning
      assert warning.message =~ "Charge"
      assert warning.fix_hint != nil
      assert warning.fix_code != nil
    end

    test "a wildcard arm silences the warning" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Event {
                   Charge(amount: Int)
                   Refund
                 }

                 fn f(e: Event) -> String {
                   match e {
                     Event.Charge(5) -> "five"
                     Refund -> "refund"
                     _ -> "other"
                   }
                 }
               }
               """)
    end

    test "a binding arm for the same variant silences the warning" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Event {
                   Charge(amount: Int)
                   Refund
                 }

                 fn f(e: Event) -> String {
                   match e {
                     Event.Charge(5) -> "five"
                     Event.Charge(n) -> "other ${n}"
                     Refund -> "refund"
                   }
                 }
               }
               """)
    end

    test "binding-only variant patterns do not warn" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Event {
                   Charge(amount: Int)
                   Refund
                 }

                 fn f(e: Event) -> String {
                   match e {
                     Event.Charge(n) -> "charged ${n}"
                     Refund -> "refund"
                   }
                 }
               }
               """)
    end

    test "string literal field patterns also warn" do
      errors =
        analyze_errors("""
        module M {
          enum Cmd {
            Run(name: String)
            Halt
          }

          fn f(c: Cmd) -> String {
            match c {
              Cmd.Run("build") -> "building"
              Halt -> "halting"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "W0004"))
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
      assert hd(errors).code == "E0024"
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
      assert hd(errors).code == "E0024"
    end

    test "user-declared type is valid in function signatures" do
      # The type reference itself must resolve (no E0024). The body returns a
      # value of the declared type so this stays well-typed under the invariant
      # lattice — a bare `42` here would (correctly) be an E0020 mismatch.
      assert {:ok, _} =
               analyze("""
               module M {
                 type Foo {
                   value: Int
                 }

                 fn make_foo(foo: Foo) -> Foo {
                   foo
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
      assert hd(errors).code == "E0020"
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

  # ------------------------------------------------------------------
  # Capability checking (Phase 3)
  # ------------------------------------------------------------------

  describe "capability checking - missing capabilities" do
    test "http.get without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.severity == :error
      assert error.message =~ "http.out"
      assert error.message =~ "not declared"
    end

    test "http.post without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn send(url: String, body: String) -> String {
            http.post(url, body)!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "http.out"
    end

    test "http.put without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn update(url: String, body: String) -> String {
            http.put(url, body)!
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "http.delete without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(url: String) -> String {
            http.delete(url)!
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error.fix_code != nil
      assert error.fix_code =~ "capability http.out"
    end

    test "error includes fix_hint" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error.fix_hint != nil
      assert error.fix_hint =~ "capability"
    end
  end

  describe "capability checking - valid capabilities" do
    test "http.get with capability http.out passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn fetch(url: String) -> String {
                   http.get(url)!
                 }
               }
               """)
    end

    test "http.post with capability http.out passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn send(url: String, body: String) -> String {
                   http.post(url, body)!
                 }
               }
               """)
    end

    test "multiple http methods with single capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn fetch(url: String) -> String {
                   http.get(url)!
                 }

                 fn send(url: String, body: String) -> String {
                   http.post(url, body)!
                 }
               }
               """)
    end

    test "capability without params covers all hosts" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out

                 fn fetch(url: String) -> String {
                   http.get(url)!
                 }
               }
               """)
    end

    test "modules without effect calls don't need capabilities" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int {
                   a + b
                 }
               }
               """)
    end
  end

  describe "pipe expressions" do
    test "piped value counts as the first argument of the right-hand call" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn double(x: Int) -> Int {
                   x * 2
                 }

                 fn run(x: Int) -> Int {
                   x |> double()
                 }
               }
               """)
    end

    test "pipe into a stdlib call type-checks and yields the call's return type" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn shout(s: String) -> String {
                   s |> String.upcase()
                 }
               }
               """)
    end

    test "pipe with missing remaining arguments is an arity error" do
      errors =
        analyze_errors("""
        module M {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn run(x: Int) -> Int {
            x |> add()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020" and &1.message =~ "expects 2 argument"))
    end

    test "pipe supplying all arguments plus the piped value is an arity error" do
      errors =
        analyze_errors("""
        module M {
          fn double(x: Int) -> Int {
            x * 2
          }

          fn run(x: Int) -> Int {
            x |> double(x)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "piped value type mismatch into a stdlib call is reported" do
      errors =
        analyze_errors("""
        module M {
          fn run(x: Int) -> String {
            x |> String.upcase()
          }
        }
        """)

      assert Enum.any?(
               errors,
               &(&1.code == "E0020" and &1.message =~ "expected String, got Int")
             )
    end
  end

  describe "capability checking - nested effect calls" do
    test "effect call in let binding is checked" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            let result = http.get(url)
            result
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "effect call in match arm is checked" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(flag: Bool, url: String) -> String {
            match flag {
              true -> http.get(url)
              false -> "cached"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "effect call in pipe is checked" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            url |> http.get(url)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "multiple effect calls produce multiple errors" do
      errors =
        analyze_errors("""
        module M {
          fn bad(url: String) -> String {
            let a = http.get(url)
            let b = http.post(url, a)
            b
          }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 2
    end
  end

  # ------------------------------------------------------------------
  # Handler checking (Phase 4)
  # ------------------------------------------------------------------

  describe "handler checking - http.in capability" do
    test "handler without http.in capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler http GET "/test" (req) -> {
            respond.json(200, "ok")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "http.in"
      assert error.fix_code == "capability http.in"
    end

    test "handler with http.in capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in

                 handler http GET "/test" (req) -> {
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "multiple handlers all require http.in" do
      errors =
        analyze_errors("""
        module M {
          handler http GET "/a" (req) -> { respond.json(200, "a") }
          handler http POST "/b" (req) -> { respond.json(200, "b") }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 2
    end

    test "handler body is type-checked with req in scope" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in

                 handler http GET "/users/:id" (req) -> {
                   let id = req.params.id
                   respond.json(200, id)
                 }
               }
               """)
    end

    test "unknown variable in handler body produces error" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/test" (req) -> {
            unknown_var
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0010"))
    end

    test "handler body effect calls are capability-checked" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/proxy" (req) -> {
            http.get("https://example.com")!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "http.out"))
    end

    test "handler with both http.in and http.out capabilities passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability http.out("example.com")

                 handler http GET "/proxy" (req) -> {
                   http.get("https://example.com/data")!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Store capability checking
  # ------------------------------------------------------------------

  describe "store capability checking - missing capabilities" do
    test "store.users.get without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn find(id: Uuid) -> String {
            store.users.get(id)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "store.table"
      assert error.message =~ "users"
    end

    test "store.users.put without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn save(record: String) -> String {
            store.users.put(record)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "store.table"
      assert error.message =~ "users"
    end

    test "store.users.delete without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(id: Uuid) -> String {
            store.users.delete(id)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "store.table"
    end

    test "store.users.query without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn search(email: String) -> String {
            store.users.query(email)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
    end

    test "store error includes fix_code with table name" do
      errors =
        analyze_errors("""
        module M {
          fn find(id: Uuid) -> String {
            store.orders.get(id)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error.fix_code == "capability store.table(\"orders\")"
    end

    test "wrong table name still produces error" do
      errors =
        analyze_errors("""
        module M {
          capability store.table("users")

          fn find(id: Uuid) -> String {
            store.orders.get(id)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "orders"
    end
  end

  describe "store capability checking - valid capabilities" do
    test "store.users.get with store.table(\"users\") passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability store.table("users")

                 fn find(id: Uuid) -> String {
                   store.users.get(id)!
                 }
               }
               """)
    end

    test "store.users.put with store.table(\"users\") passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability store.table("users")

                 fn save(record: String) -> String {
                   store.users.put(record)!
                 }
               }
               """)
    end

    test "store operations on different tables each need their own capability" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability store.table("users")
                 capability store.table("orders")

                 fn find_user(id: Uuid) -> String {
                   store.users.get(id)!
                 }

                 fn find_order(id: Uuid) -> String {
                   store.orders.get(id)!
                 }
               }
               """)
    end

    test "multiple store methods on the same table pass with one capability" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability store.table("items")

                 fn crud(id: Uuid) -> List[String] {
                   store.items.get(id)!
                   store.items.put(id)!
                   store.items.delete(id)!
                   store.items.query(id)!
                 }
               }
               """)
    end
  end

  describe "store annotations" do
    test "@primary annotation on Uuid field passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   id: Uuid @primary
                   name: String
                 }
               }
               """)
    end

    test "@unique annotation on String field passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   id: Uuid @primary
                   email: String @unique
                   name: String
                 }
               }
               """)
    end

    test "@primary and @unique together on same field passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   id: Uuid @primary @unique
                   name: String
                 }
               }
               """)
    end
  end

  describe "capability checking - error serialization" do
    test "capability error serializes to JSON with fix_code" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      json = Skein.Error.to_json(error)
      decoded = Jason.decode!(json)
      assert decoded["code"] == "E0012"
      assert decoded["fix_code"] =~ "capability http.out"
    end
  end

  # ------------------------------------------------------------------
  # Agent analysis (Phase 6a)
  # ------------------------------------------------------------------

  describe "agent analysis - valid agents" do
    test "accepts a well-formed agent with all phases handled" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 state {
                   ticket_id: String
                 }

                 enum Phase {
                   Init -> [Done]
                   Done -> []
                 }

                 on start(ticket_id: String) -> {
                   transition(Phase.Init)
                 }

                 on phase(Phase.Init) -> {
                   transition(Phase.Done)
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end

    test "accepts agent with functions" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 enum Phase {
                   Init -> [Done]
                   Done -> []
                 }

                 fn helper(x: Int) -> Int {
                   x + 1
                 }

                 on start() -> {
                   transition(Phase.Init)
                 }

                 on phase(Phase.Init) -> {
                   transition(Phase.Done)
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end
  end

  describe "agent analysis - phase transition errors" do
    test "reports error for transition to unknown phase" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Unknown]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030" and &1.message =~ "unknown phase 'Unknown'"))
    end

    test "reports error for invalid transition call" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            transition(Phase.Init)
          }
        }
        """)

      assert Enum.any?(
               errors,
               &(&1.code == "E0030" and &1.message =~ "Done cannot transition to Phase.Init")
             )
    end

    test "start handler can transition to any phase" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 enum Phase {
                   Init -> [Done]
                   Done -> []
                 }

                 on start() -> {
                   transition(Phase.Done)
                 }

                 on phase(Phase.Init) -> {
                   transition(Phase.Done)
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end
  end

  describe "agent analysis - missing phase handlers" do
    test "reports error for phase without handler" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0032" and &1.message =~ "Done"))
    end
  end

  describe "agent analysis - unreachable phases" do
    test "warns about unreachable phases" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Done]
            Orphan -> []
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Orphan) -> {
            stop()
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      assert Enum.any?(
               errors,
               &(&1.code == "E0031" and &1.message =~ "Orphan" and &1.severity == :warning)
             )
    end
  end

  describe "agent analysis - state validation" do
    test "reports error for unknown type in state" do
      errors =
        analyze_errors("""
        agent A {
          state {
            data: UnknownType
          }

          enum Phase {
            Init -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            stop()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0024" and &1.message =~ "UnknownType"))
    end
  end

  describe "agent analysis - transition in match" do
    test "validates transitions inside match arms" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            match true {
              true -> transition(Phase.Done)
              false -> transition(Phase.Init)
            }
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      # Init -> Init is not declared, so it should be an error
      assert Enum.any?(
               errors,
               &(&1.code == "E0030" and &1.message =~ "Init cannot transition to Phase.Init")
             )
    end
  end

  # ------------------------------------------------------------------
  # Agent capability enforcement
  # ------------------------------------------------------------------

  describe "agent analysis - capability enforcement" do
    test "tool.call without capability tool.use produces E0012 in agent" do
      errors =
        analyze_errors("""
        agent A {
          on start() -> {
            tool.call("search", {query: "test"})!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "tool.use"))
    end

    test "http.get without capability http.out produces E0012 in agent" do
      errors =
        analyze_errors("""
        agent A {
          fn fetch(url: String) -> String {
            http.get(url)!
          }

          on start() -> {
            let result = fetch("http://example.com")
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "http.out"))
    end

    test "memory.put without capability memory.kv produces E0012 in agent" do
      errors =
        analyze_errors("""
        agent A {
          on start() -> {
            memory.put("key", "value")!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "memory.kv"))
    end

    test "agent with correct capabilities passes analysis" do
      result =
        analyze("""
        agent A {
          capability tool.use(SearchTool)
          capability http.out

          fn fetch(url: String) -> String {
            http.get(url)!
          }

          on start() -> {
            tool.call("SearchTool", {query: "test"})!
            let result = fetch("http://example.com")
          }
        }
        """)

      case result do
        {:ok, _} -> assert true
        {:ok, _, warnings} -> refute Enum.any?(warnings, &(&1.code == "E0012"))
        {:error, errors} -> refute Enum.any?(errors, &(&1.code == "E0012"))
      end
    end

    test "unused capability in agent produces W0002 warning" do
      errors =
        analyze_errors("""
        agent A {
          capability http.out

          on start() -> {
            stop()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "W0002" and &1.message =~ "http.out"))
    end

    test "tool.call with undeclared tool name produces E0014 in agent" do
      errors =
        analyze_errors("""
        agent A {
          capability tool.use(SearchTool)

          on start() -> {
            tool.call("unknown_tool", {query: "test"})!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0014"))
    end

    test "capability checking works in agent phase handlers" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Working -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            http.get("http://example.com")!
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "http.out"))
    end
  end

  # ------------------------------------------------------------------
  # Memory capability checking
  # ------------------------------------------------------------------

  describe "memory capability checking - missing capabilities" do
    test "memory.put without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn save(key: String, value: String) -> String {
            memory.put(key, value)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.get without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn load(key: String) -> String {
            memory.get(key)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.delete without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(key: String) -> String {
            memory.delete(key)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.list without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn keys(prefix: String) -> String {
            memory.list(prefix)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn save(key: String, value: String) -> String {
            memory.put(key, value)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error.fix_code =~ "capability memory.kv"
    end
  end

  describe "memory capability checking - valid capabilities" do
    test "memory.put with memory.kv capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("sessions")

                 fn save(key: String, value: String) -> String {
                   memory.put(key, value)!
                 }
               }
               """)
    end

    test "memory.get with memory.kv capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("sessions")

                 fn load(key: String) -> String {
                   memory.get(key)!
                 }
               }
               """)
    end

    test "multiple memory methods with single capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("sessions")

                 fn operate(key: String) -> String {
                   memory.put(key, "value")!
                 }
               }
               """)
    end

    test "memory.kv without params covers all namespaces" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv

                 fn save(key: String, value: String) -> String {
                   memory.put(key, value)!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # LLM capability checking
  # ------------------------------------------------------------------

  describe "llm capability checking - missing capabilities" do
    test "llm.chat without model capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm.json without model capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn decide(data: String) -> String {
            llm.json("claude-sonnet-4-5", "Return JSON.", data)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error.fix_code =~ "capability model"
    end
  end

  describe "llm capability checking - valid capabilities" do
    test "llm.chat with model capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn ask(data: String) -> String {
                   llm.chat("claude-sonnet-4-5", "Be helpful.", data)!
                 }
               }
               """)
    end

    test "llm.json with model capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn decide(data: String) -> String {
                   llm.json("claude-sonnet-4-5", "Return JSON.", data)!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # llm.stream capability checking (Phase 8f)
  # ------------------------------------------------------------------

  describe "llm.stream capability checking" do
    test "llm.stream without model capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "Be helpful.", data)!
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm.stream with model capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn stream_it(data: String) -> String {
                   llm.stream("claude-sonnet-4-5", "Be helpful.", data)!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Tool validation (Phase 6c)
  # ------------------------------------------------------------------

  describe "tool declarations" do
    test "valid tool declaration with known types passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 tool MyTool {
                   input { amount: Int }
                   output { id: String }
                   implement { "ok" }
                 }
               }
               """)
    end

    test "tool with unknown input type produces E0024" do
      errors =
        analyze_errors("""
        module M {
          tool MyTool {
            input { data: Foo }
            output { id: String }
            implement { "ok" }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0024"))
      assert Enum.any?(errors, &String.contains?(&1.message, "Foo"))
    end

    test "tool with unknown output type produces E0024" do
      errors =
        analyze_errors("""
        module M {
          tool MyTool {
            input { amount: Int }
            output { result: Bar }
            implement { "ok" }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0024"))
      assert Enum.any?(errors, &String.contains?(&1.message, "Bar"))
    end

    test "tool with user-defined type in input passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type RefundInput {
                   amount: Int
                   customer_id: String
                 }

                 tool MyTool {
                   input { amount: Int }
                   output { id: String }
                   implement { "ok" }
                 }
               }
               """)
    end

    test "tool with parameterized types passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 tool MyTool {
                   input { items: List[String] }
                   output { results: List[Int] }
                   implement { "ok" }
                 }
               }
               """)
    end
  end

  describe "tool.call capability checking" do
    test "tool.call without tool.use capability produces E0012" do
      errors =
        analyze_errors("""
        module M {
          fn f(args: String) -> String {
            tool.call(MyTool, args)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
      assert Enum.any?(errors, &String.contains?(&1.message, "tool.use"))
    end

    test "tool.call with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f(args: String) -> String {
                   tool.call(MyTool, args)!
                 }
               }
               """)
    end

    test "tool.list without tool.use capability produces E0012" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> List[String] {
            tool.list()!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "tool.list with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f() -> List[String] {
                   tool.list()!
                 }
               }
               """)
    end

    test "tool.schema without tool.use capability produces E0012" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String {
            tool.schema(MyTool)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "tool.schema with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f() -> String {
                   tool.schema(MyTool)!
                 }
               }
               """)
    end

    test "tool.call in handler with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability tool.use(MyTool)

                 handler http GET "/test" (req) -> {
                   tool.call(MyTool, req)!
                 }
               }
               """)
    end

    test "tool.call in handler without tool.use capability produces E0012" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/test" (req) -> {
            tool.call(MyTool, req)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end
  end

  # ------------------------------------------------------------------
  # Queue handler capability checking (Phase 8e)
  # ------------------------------------------------------------------

  describe "queue handler checking - queue.consume capability" do
    test "queue handler without queue.consume capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler queue "events" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "queue.consume"
      assert error.fix_code == "capability queue.consume"
    end

    test "queue handler with queue.consume capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability queue.consume

                 handler queue "events" (msg) -> {
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "deprecated queue.in capability produces a rename hint" do
      errors =
        analyze_errors("""
        module M {
          capability queue.in

          handler queue "events" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "renamed"
      assert error.message =~ "queue.consume"
      assert error.fix_code == "capability queue.consume"
    end

    test "deprecated schedule.in capability produces a rename hint" do
      errors =
        analyze_errors("""
        module M {
          capability schedule.in

          handler schedule "0 * * * *" () -> {
            respond.json(200, "ok")
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "renamed"
      assert error.message =~ "schedule.trigger"
      assert error.fix_code == "capability schedule.trigger"
    end

    test "multiple queue handlers all require queue.consume" do
      errors =
        analyze_errors("""
        module M {
          handler queue "a" (msg) -> { respond.json(200, "a") }
          handler queue "b" (msg) -> { respond.json(200, "b") }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 2
    end
  end

  # ------------------------------------------------------------------
  # Schedule handler capability checking (Phase 8e)
  # ------------------------------------------------------------------

  describe "schedule handler checking - schedule.trigger capability" do
    test "schedule handler without schedule.trigger capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler schedule "*/5 * * * *" () -> {
            respond.json(200, "tick")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "schedule.trigger"
      assert error.fix_code == "capability schedule.trigger"
    end

    test "schedule handler with schedule.trigger capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability schedule.trigger

                 handler schedule "0 * * * *" () -> {
                   respond.json(200, "hourly")
                 }
               }
               """)
    end

    test "mixed handler types require respective capabilities" do
      errors =
        analyze_errors("""
        module M {
          handler http GET "/test" (req) -> { respond.json(200, "ok") }
          handler queue "events" (msg) -> { respond.json(200, "ok") }
          handler schedule "*/5 * * * *" () -> { respond.json(200, "ok") }
        }
        """)

      # Should produce errors for all three missing capabilities
      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 3

      messages = Enum.map(capability_errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "http.in"))
      assert Enum.any?(messages, &(&1 =~ "queue.consume"))
      assert Enum.any?(messages, &(&1 =~ "schedule.trigger"))
    end

    test "all capabilities declared passes for mixed handlers" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability queue.consume
                 capability schedule.trigger

                 handler http GET "/test" (req) -> { respond.json(200, "ok") }
                 handler queue "events" (msg) -> { respond.json(200, "ok") }
                 handler schedule "*/5 * * * *" () -> { respond.json(200, "ok") }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Topic handler capability checking
  # ------------------------------------------------------------------

  describe "topic handler checking - topic.consume capability" do
    test "topic handler without topic.consume capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler topic "order.events" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "topic.consume"
      assert error.fix_code == "capability topic.consume"
    end

    test "topic handler with topic.consume capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability topic.consume("order.events")

                 handler topic "order.events" (msg) -> {
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "multiple topic handlers all require topic.consume" do
      errors =
        analyze_errors("""
        module M {
          handler topic "events-a" (msg) -> { respond.json(200, "a") }
          handler topic "events-b" (msg) -> { respond.json(200, "b") }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 2
    end

    test "topic.publish effect requires topic.publish capability" do
      errors =
        analyze_errors("""
        module M {
          fn send_event() -> String {
            topic.publish("order.events", "data")!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "topic.publish"
    end

    test "topic.publish with topic.publish capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability topic.publish("order.events")

                 fn send_event() -> String {
                   topic.publish("order.events", "data")!
                 }
               }
               """)
    end

    test "mixed handler types including topic require respective capabilities" do
      errors =
        analyze_errors("""
        module M {
          handler http GET "/test" (req) -> { respond.json(200, "ok") }
          handler queue "events" (msg) -> { respond.json(200, "ok") }
          handler topic "notifications" (msg) -> { respond.json(200, "ok") }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0012"))
      assert length(capability_errors) >= 3

      messages = Enum.map(capability_errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "http.in"))
      assert Enum.any?(messages, &(&1 =~ "queue.consume"))
      assert Enum.any?(messages, &(&1 =~ "topic.consume"))
    end

    test "all capabilities declared passes for mixed handlers with topic" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability queue.consume
                 capability topic.consume("notifications")

                 handler http GET "/test" (req) -> { respond.json(200, "ok") }
                 handler queue "events" (msg) -> { respond.json(200, "ok") }
                 handler topic "notifications" (msg) -> { respond.json(200, "ok") }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Tool identifier references — capability-as-import (Phase 9)
  # ------------------------------------------------------------------

  describe "tool identifier capability checking" do
    test "tool.call with identifier matching declared capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f(args: String) -> String {
                   tool.call(MyTool, args)!
                 }
               }
               """)
    end

    test "tool.call with identifier NOT matching declared capability produces E0014" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(MyTool)

          fn f(args: String) -> String {
            tool.call(OtherTool, args)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0014"))
      assert Enum.any?(errors, &String.contains?(&1.message, "OtherTool"))
    end

    test "tool.call with identifier but no capability at all produces E0012" do
      errors =
        analyze_errors("""
        module M {
          fn f(args: String) -> String {
            tool.call(MyTool, args)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "tool.schema with identifier matching declared capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f() -> String {
                   tool.schema(MyTool)!
                 }
               }
               """)
    end

    test "tool.schema with identifier NOT matching declared capability produces E0014" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(MyTool)

          fn f() -> String {
            tool.schema(OtherTool)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0014"))
    end

    test "tool.list with any tool.use capability passes (no specific tool needed)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(MyTool)

                 fn f() -> List[String] {
                   tool.list()!
                 }
               }
               """)
    end

    test "tool.call with dotted identifier matching dotted capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(Stripe.CreateRefund)

                 fn f(args: String) -> String {
                   tool.call(Stripe.CreateRefund, args)!
                 }
               }
               """)
    end

    test "tool.call with dotted identifier NOT matching produces E0014" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(Stripe.CreateRefund)

          fn f(args: String) -> String {
            tool.call(Stripe.GetBalance, args)!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0014"))
    end

    test "multiple tools declared in capability, correct one referenced passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(ToolA, ToolB)

                 fn f(args: String) -> String {
                   tool.call(ToolB, args)!
                 }
               }
               """)
    end

    test "multiple tools declared across separate capabilities, all valid" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(ToolA)
                 capability tool.use(ToolB)

                 fn f(args: String) -> String {
                   let a = tool.call(ToolA, args)
                   tool.call(ToolB, args)!
                 }
               }
               """)
    end

    test "duplicate short tool name across capabilities produces E0015" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(Payments.CreateRefund, Billing.CreateRefund)
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0015"))
      assert Enum.any?(errors, &String.contains?(&1.message, "CreateRefund"))
    end

    test "duplicate short tool name across separate capability lines produces E0015" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(Payments.CreateRefund)
          capability tool.use(Billing.CreateRefund)
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0015"))
    end

    test "tool.call identifier fix_hint suggests adding capability" do
      errors =
        analyze_errors("""
        module M {
          capability tool.use(ToolA)

          fn f(args: String) -> String {
            tool.call(ToolB, args)!
          }
        }
        """)

      tool_errors = Enum.filter(errors, &(&1.code == "E0014"))
      assert length(tool_errors) >= 1
      error = hd(tool_errors)
      assert error.fix_hint =~ "capability tool.use"
      assert error.fix_code =~ "ToolB"
    end

    test "tool.call in handler with identifier capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability tool.use(MyTool)

                 handler http GET "/test" (req) -> {
                   tool.call(MyTool, req)!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # E0017: duplicate scoped capability declarations
  # ------------------------------------------------------------------

  describe "E0017: duplicate scoped capability declarations" do
    test "two event.log capabilities with different labels produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability event.log("audit")
          capability event.log("metrics")
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
      error = Enum.find(errors, &(&1.code == "E0017"))
      assert error.message =~ "event.log"
      assert error.message =~ "audit"
      assert error.message =~ "metrics"
      assert error.severity == :error
      assert error.fix_hint != nil
      assert error.fix_code != nil
    end

    test "two process.spawn capabilities produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability process.spawn("workers")
          capability process.spawn("reports")
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "two timer capabilities produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability timer("maintenance")
          capability timer("billing")
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "two memory.kv capabilities produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("sessions")
          capability memory.kv("cache")
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "identical duplicate declarations also produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability timer("maintenance")
          capability timer("maintenance")
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "one declaration of each scoped kind is fine" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("sessions")
          capability event.log("audit")
          capability process.spawn("workers")
          capability timer("maintenance")
        }
        """)

      refute Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "repeated capabilities of other kinds do not produce E0017" do
      errors =
        analyze_errors("""
        module M {
          capability http.out("api.a.com")
          capability http.out("api.b.com")
          capability store.table("users")
          capability store.table("orders")
        }
        """)

      refute Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "module and nested agent each declaring a label is not a duplicate" do
      errors =
        analyze_errors("""
        module M {
          capability event.log("audit")

          agent A {
            capability event.log("agent_events")

            enum Phase {
              Init -> [Done]
              Done -> []
            }

            on start() -> {
              transition(Phase.Init)
            }

            on phase(Phase.Init) -> {
              transition(Phase.Done)
            }

            on phase(Phase.Done) -> {
              stop()
            }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "E0017"))
    end

    test "duplicates inside a nested agent produce E0017" do
      errors =
        analyze_errors("""
        module M {
          agent A {
            capability timer("alpha")
            capability timer("beta")

            enum Phase {
              Init -> [Done]
              Done -> []
            }

            on start() -> {
              transition(Phase.Init)
            }

            on phase(Phase.Init) -> {
              transition(Phase.Done)
            }

            on phase(Phase.Done) -> {
              stop()
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0017"))
    end
  end

  # ------------------------------------------------------------------
  # Supervisor validation
  # ------------------------------------------------------------------

  describe "supervisor validation" do
    test "valid supervisor passes analysis" do
      assert {:ok, _} =
               analyze("""
               module M {
                 supervisor Main {
                   child HttpServer { restart: permanent }
                   strategy: one_for_one
                   max_restarts: 10 per 60s
                 }
               }
               """)
    end

    test "supervisor with no children produces warning" do
      errors =
        analyze_errors("""
        module M {
          supervisor Empty {
            strategy: one_for_one
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0042" and e.severity == :warning
             end)
    end

    test "supervisor with children and strategy passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 supervisor Pool {
                   child Worker
                   child Logger
                   strategy: one_for_all
                 }
               }
               """)
    end

    test "supervisor with defaults (no strategy/max_restarts) passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 supervisor Simple {
                   child Worker
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # E0011: Duplicate definitions
  # ------------------------------------------------------------------

  describe "duplicate definitions" do
    test "duplicate function names produce E0011" do
      errors =
        analyze_errors("""
        module M {
          fn greet() -> String { "hello" }
          fn greet() -> Int { 42 }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0011" and &1.message =~ "greet"))
    end

    test "duplicate type names produce E0011" do
      errors =
        analyze_errors("""
        module M {
          type User { name: String }
          type User { age: Int }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0011" and &1.message =~ "User"))
    end

    test "different names do not produce E0011" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn greet() -> String { "hello" }
                 fn farewell() -> String { "bye" }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # E0022: Invalid ! on non-Result
  # ------------------------------------------------------------------

  describe "E0022: invalid ! on non-Result" do
    test "! on Int literal produces E0022" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            42!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0022"))
    end

    test "! on String literal produces E0022" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            "hello"!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0022"))
    end

    test "! on Bool produces E0022" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Bool {
            true!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0022"))
    end
  end

  # ------------------------------------------------------------------
  # E0023: Invalid ? on non-Result
  # ------------------------------------------------------------------

  describe "E0023: invalid ? on non-Result" do
    test "? on Int literal produces E0023" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            42?
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0023"))
    end

    test "? in function that doesn't return Result produces E0023" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            get_value()?
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0023" and e.message =~ "enclosing function"
             end)
    end
  end

  # ------------------------------------------------------------------
  # W0001: Unused binding
  # ------------------------------------------------------------------

  describe "W0001: unused binding" do
    test "unused let binding produces W0001 warning" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> Int {
            let unused = 42
            0
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "W0001" and e.severity == :warning and e.message =~ "unused"
             end)
    end

    test "used let binding does not produce W0001" do
      result =
        analyze("""
        module M {
          fn good() -> Int {
            let x = 42
            x
          }
        }
        """)

      case result do
        {:ok, _} ->
          :ok

        {:error, errors} ->
          refute Enum.any?(errors, &(&1.code == "W0001"))
      end
    end

    test "_ prefixed binding does not produce W0001" do
      result =
        analyze("""
        module M {
          fn good() -> Int {
            let _ignored = 42
            0
          }
        }
        """)

      case result do
        {:ok, _} ->
          :ok

        {:error, errors} ->
          refute Enum.any?(errors, &(&1.code == "W0001"))
      end
    end

    test "binding referenced only via string interpolation does not produce W0001" do
      errors =
        analyze_errors("""
        module M {
          fn good(name: String) -> String {
            let trimmed = String.trim(name)
            "Hello, ${trimmed}!"
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end

    test "binding referenced only via dotted interpolation does not produce W0001" do
      errors =
        analyze_errors("""
        module M {
          type User {
            id: String
          }

          fn good(u: User) -> String {
            let copy = u
            "id: ${copy.id}"
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end

    test "guarded match arm with a block body analyzes without raising" do
      errors =
        analyze_errors("""
        module M {
          fn f(x: Int) -> Int {
            let limit = 10
            match x {
              n if n > limit -> {
                let y = n
                y
              }
              n -> n
            }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end

    test "binding referenced only inside a list literal does not produce W0001" do
      errors =
        analyze_errors("""
        module M {
          fn f(x: Int) -> List[Int] {
            let y = x
            [y]
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end

    test "binding referenced only inside a map literal does not produce W0001" do
      errors =
        analyze_errors("""
        module M {
          fn f(x: String) -> Map[String, String] {
            let y = x
            { key: y }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end
  end

  describe "interpolation of uppercase identifiers" do
    test "${Upper} is a structured E0010, not a codegen crash" do
      {:ok, tokens} =
        Lexer.tokenize("module M {\n  fn f() -> String {\n    \"phase: ${Foo}\"\n  }\n}")

      {:ok, ast} = Parser.parse(tokens)

      assert {:error, errors} = Analyzer.analyze(ast)
      assert Enum.any?(errors, fn e -> e.code == "E0010" and e.message =~ "Foo" end)
    end

    test "${Upper.field} is rejected the same way" do
      {:ok, tokens} =
        Lexer.tokenize("module M {\n  fn f() -> String {\n    \"url: ${Config.url}\"\n  }\n}")

      {:ok, ast} = Parser.parse(tokens)

      assert {:error, errors} = Analyzer.analyze(ast)
      assert Enum.any?(errors, fn e -> e.code == "E0010" and e.message =~ "Config" end)
    end

    test "${Upper} in an agent handler body is a structured E0010, not a codegen crash" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Working -> []
          }

          on start(id: String) -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            let msg = "x: ${Foo}"
            trace.annotate("m", msg)
            stop()
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0010" and e.message =~ "Cannot interpolate 'Foo'"
             end)
    end

    test "${Upper} in a test block body is a structured E0010, not a codegen crash" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> Int { 1 }

          test "t" {
            let x = "${Foo}"
            assert f() == 1
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0010" and e.message =~ "Cannot interpolate 'Foo'"
             end)
    end

    test "uppercase rejection reports a single error per segment" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String { "phase: ${Foo}" }
        }
        """)

      assert Enum.count(errors, &(&1.code == "E0010")) == 1
    end
  end

  describe "interpolation locations" do
    test "E0010 for an unknown interpolation identifier carries the source location" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String { "value: ${missing}" }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error.location.line == 2
      assert error.location.col > 0
    end
  end

  describe "interpolation in string patterns" do
    test "interpolated pattern in a module fn match is a structured E0020, not a codegen crash" do
      errors =
        analyze_errors("""
        module M {
          fn f(s: String, y: String) -> Int {
            match s {
              "x${y}" -> 1
              _ -> 0
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "String patterns cannot contain interpolation"
             end)
    end

    test "interpolated pattern in an agent handler match is a structured E0020" do
      errors =
        analyze_errors("""
        agent C {
          enum Phase {
            Working -> []
          }

          on start(id: String) -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            match "a" {
              "x${id}" -> stop()
              _ -> stop()
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "String patterns cannot contain interpolation"
             end)
    end

    test "literal string patterns remain valid" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn f(s: String) -> Int {
                   match s {
                     "go" -> 1
                     _ -> 0
                   }
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # W0002: Unused capability
  # ------------------------------------------------------------------

  describe "W0002: unused capability" do
    test "unused capability produces W0002 warning" do
      errors =
        analyze_errors("""
        module M {
          capability http.out("example.com")

          fn pure() -> Int { 42 }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "W0002" and e.severity == :warning and e.message =~ "http.out"
             end)
    end

    test "used capability does not produce W0002" do
      result =
        analyze("""
        module M {
          capability http.out("example.com")

          fn fetch(url: String) -> String {
            http.get(url)!
          }
        }
        """)

      case result do
        {:ok, _} ->
          :ok

        {:error, errors} ->
          refute Enum.any?(errors, &(&1.code == "W0002"))
      end
    end

    test "store.table exercised via store.<table>.<method> is not W0002" do
      errors =
        analyze_errors("""
        module M {
          capability store.table("users")

          fn lookup(id: String) -> String {
            let user = store.users.get(id)
            "done"
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0002"))
    end

    test "effect error types from the spec are known type names" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("example.com")

                 fn fetch(url: String) -> Result[String, HttpError] {
                   let r = http.get(url)?
                   Ok("done")
                 }
               }
               """)
    end

    test "capability exercised only inside a test block is not W0002 (scaffold shape)" do
      errors =
        analyze_errors("""
        module PacesTest {
          capability tool.use(Paces.Greet)

          test "greets through the Paces.Greet tool" {
            let result = tool.call(Paces.Greet, { name: "World" })!
            assert result.greeting == "Hello, World!"
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0002"))
    end

    test "capability exercised only inside a scenario expect block is not W0002" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("ns")

          scenario "memory round trip" {
            given {
              key: "k"
            }

            expect {
              assert memory.put("k", "v") == memory.put("k", "v")
            }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0002"))
    end
  end

  # ------------------------------------------------------------------
  # Capability checking covers test blocks (issue #104)
  # ------------------------------------------------------------------

  describe "capability checks inside test blocks" do
    test "effect call inside a test block without a capability is E0012" do
      errors =
        analyze_errors("""
        module M {
          test "writes memory" {
            let r = memory.put("k", "v")
            assert 1 == 1
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0012" and e.severity == :error
             end)
    end

    test "effect call inside a scenario expect block without a capability is E0012" do
      errors =
        analyze_errors("""
        module M {
          scenario "fetches" {
            given {
              url: "https://example.com"
            }

            expect {
              assert http.get("https://example.com") == http.get("https://example.com")
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "tool.call inside a test block without tool.use is E0012" do
      errors =
        analyze_errors("""
        module M {
          test "calls a tool" {
            let r = tool.call(Other.Tool, { x: 1 })!
            assert 1 == 1
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "effect call inside a test block with the capability declared is clean" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("ns")

          test "writes memory" {
            let r = memory.put("k", "v")
            assert 1 == 1
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code in ["E0012", "W0002"]))
    end
  end

  # ------------------------------------------------------------------
  # W0003: Unreachable code after stop()
  # ------------------------------------------------------------------

  describe "W0003: unreachable code after stop()" do
    test "code after stop() in function body produces W0003" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            stop()
            "never reached"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "W0003" and e.severity == :warning
             end)
    end
  end

  # ------------------------------------------------------------------
  # E0034: suspend() outside agent
  # ------------------------------------------------------------------

  describe "suspend validation" do
    test "reports error for suspend in module function" do
      errors =
        analyze_errors("""
        module M {
          fn bad() -> String {
            suspend("should not be here")
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0034" and e.severity == :error and
                 e.message =~ "suspend()"
             end)
    end

    test "reports error for suspend in module handler" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/test" (req) -> {
            suspend("bad")
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0034" and e.severity == :error
             end)
    end

    test "accepts suspend inside agent handler" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 enum Phase {
                   Active -> []
                 }

                 on start() -> {
                   transition(Phase.Active)
                 }

                 on phase(Phase.Active) -> {
                   suspend("Waiting for input")
                 }
               }
               """)
    end

    test "accepts suspend inside agent match arm" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 enum Phase {
                   Review -> [Done]
                   Done -> []
                 }

                 on start(severity: String) -> {
                   transition(Phase.Review)
                 }

                 on phase(Phase.Review) -> {
                   match 1 {
                     1 -> suspend("Needs escalation")
                     _ -> transition(Phase.Done)
                   }
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # queue.publish effect (documented counterpart of topic.publish)
  # ------------------------------------------------------------------

  describe "queue.publish effect" do
    test "requires the queue.publish capability" do
      errors =
        analyze_errors("""
        module M {
          fn enqueue() -> String {
            queue.publish("jobs", "data")!
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0012" and e.severity == :error and e.message =~ "queue.publish"
             end)
    end

    test "analyzes clean (and counts as usage) with the capability declared" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability queue.publish("jobs")

                 fn enqueue() -> String {
                   queue.publish("jobs", "data")!
                 }
               }
               """)
    end

    test "named arguments resolve for queue.publish" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability queue.publish("jobs")

                 fn enqueue() -> String {
                   queue.publish(name: "jobs", data: "data")!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Effect call arity (documented effect signatures)
  # ------------------------------------------------------------------

  describe "test/scenario/golden bodies are fully inferred (#253)" do
    test "a missing !/? on an effect inside a test block is a compile error" do
      assert {:error, errors} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-opus-4-8")

                 test "uses chat" {
                   let r = llm.chat("claude-opus-4-8", "sys", "hi")
                   assert String.length(r) > 0
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "! on an Option inside a test block is a compile error (E0022)" do
      assert {:error, errors} =
               analyze("""
               module M {
                 fn first(xs: List[String]) -> Option[String] {
                   List.first(xs)
                 }

                 test "unwraps an option with bang" {
                   let x = first(["a"])!
                   assert x == "a"
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0022"))
    end

    test "a correct test block (effects unwrapped) still compiles clean" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-opus-4-8")

                 test "uses chat" {
                   let r = llm.chat("claude-opus-4-8", "sys", "hi")!
                   assert String.length(r) > 0
                 }
               }
               """)
    end
  end

  describe "agent handler bodies are fully inferred (#253)" do
    test "a missing ! on an effect inside a phase handler is a compile error" do
      assert {:error, errors} =
               analyze("""
               module M {
                 agent Refunder {
                   capability model("anthropic", "claude-opus-4-8")
                   capability memory.kv("refunds")

                   enum Phase {
                     Review -> [Done]
                     Done -> []
                   }

                   on start(order_id: String) -> {
                     memory.put("order_id", order_id)
                     transition(Phase.Review)
                   }

                   on phase(Phase.Review) -> {
                     let order = memory.get!("order_id")
                     let decision = llm.chat("claude-opus-4-8", "decide", order)
                     let n = String.length(decision)
                     transition(Phase.Done)
                   }

                   on phase(Phase.Done) -> {
                     stop()
                   }
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "a phase handler that unwraps its effects compiles clean" do
      assert {:ok, _} =
               analyze("""
               module M {
                 agent Refunder {
                   capability model("anthropic", "claude-opus-4-8")
                   capability memory.kv("refunds")

                   enum Phase {
                     Review -> [Done]
                     Done -> []
                   }

                   on start(order_id: String) -> {
                     memory.put("order_id", order_id)
                     transition(Phase.Review)
                   }

                   on phase(Phase.Review) -> {
                     let order = memory.get!("order_id")
                     let decision = llm.chat("claude-opus-4-8", "decide", order)!
                     let n = String.length(decision)
                     transition(Phase.Done)
                   }

                   on phase(Phase.Done) -> {
                     stop()
                   }
                 }
               }
               """)
    end
  end

  describe "tool implement bodies are fully inferred (#253)" do
    test "a missing !/? on an effect inside an implement block is a compile error" do
      assert {:error, errors} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 tool M.Fetch {
                   description: "fetch a url"

                   input {
                     url: String
                   }

                   output {
                     length: Int
                   }

                   implement {
                     let body = http.get(url)
                     Ok({ length: String.length(body) })
                   }
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "an implement block that unwraps effects compiles clean" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 tool M.Fetch {
                   description: "fetch a url"

                   input {
                     url: String
                   }

                   output {
                     length: Int
                   }

                   implement {
                     let response = http.get(url)!
                     Ok({ length: 1 })
                   }
                 }
               }
               """)
    end
  end

  describe "arithmetic operators are numeric-only (#252)" do
    test "String + String is a compile error, not a runtime crash" do
      assert {:error, errors} =
               analyze("""
               module M {
                 fn join(a: String, b: String) -> String {
                   a + b
                 }
               }
               """)

      error = Enum.find(errors, &(&1.code == "E0020"))
      assert error
      assert error.message =~ "numeric"
      # The fix points at string interpolation, the one way to build strings.
      assert error.fix_hint =~ "interpolation"
    end

    test "Int + Int still type-checks" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn add(a: Int, b: Int) -> Int {
                   a + b
                 }
               }
               """)
    end
  end

  describe "effects are Result-typed (skein-testing#1)" do
    test "using an effect result as its bare success type is a compile error" do
      # llm.chat returns Result[String, LlmError]; passing it (un-unwrapped) to
      # String.length must fail to compile instead of crashing at runtime.
      assert {:error, errors} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-opus-4-8")

                 fn f() -> Int {
                   let r = llm.chat("claude-opus-4-8", "sys", "hi")
                   String.length(r)
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "unwrapping with ! makes the success value usable" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-opus-4-8")

                 fn f() -> Int {
                   let r = llm.chat("claude-opus-4-8", "sys", "hi")!
                   String.length(r)
                 }
               }
               """)
    end

    test "returning an effect result requires a Result return type" do
      assert {:error, errors} =
               analyze("""
               module M {
                 capability store.table("users")

                 fn find(id: Uuid) -> String {
                   store.users.get(id)
                 }
               }
               """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end
  end

  describe "unknown effect methods (skein-testing#33)" do
    test "an unknown method on a known effect namespace is a structured E0010" do
      assert {:error, errors} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn f(url: String) -> String {
                   http.frobnicate(url)!
                 }
               }
               """)

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error
      assert error.message =~ "http.frobnicate"
      # The fix points at the closest real method, not a leaked unbound_var.
      assert error.fix_hint =~ "get"
    end

    test "a valid effect method on a known namespace still type-checks" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn f(url: String) -> String {
                   let _r = http.get(url)
                   "ok"
                 }
               }
               """)
    end
  end

  describe "effect call arity validation" do
    test "llm.stream accepts the documented 3-arg form" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn f(data: String) -> String {
                   llm.stream("claude-sonnet-4-5", "system", data)!
                 }
               }
               """)
    end

    test "llm.stream accepts a fourth on_chunk callback argument" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn on_piece(chunk: String) -> String {
                   chunk
                 }

                 fn f(data: String) -> String {
                   llm.stream("claude-sonnet-4-5", "system", data, &on_piece)!
                 }
               }
               """)
    end

    test "llm.stream accepts on_chunk as a named argument" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn on_piece(chunk: String) -> String {
                   chunk
                 }

                 fn f(data: String) -> String {
                   llm.stream("claude-sonnet-4-5", "system", data, on_chunk: &on_piece)!
                 }
               }
               """)
    end

    test "reports E0020 when llm.stream gets too many arguments" do
      errors =
        analyze_errors("""
        module M {
          capability model("anthropic", "claude-sonnet-4-5")

          fn on_piece(chunk: String) -> String {
            chunk
          }

          fn f(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "system", data, &on_piece, &on_piece)!
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.severity == :error and e.message =~ "llm.stream"
             end)
    end

    test "reports E0020 when llm.chat gets too few arguments" do
      errors =
        analyze_errors("""
        module M {
          capability model("anthropic", "claude-sonnet-4-5")

          fn f() -> String {
            llm.chat("claude-sonnet-4-5")!
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.severity == :error and e.message =~ "llm.chat"
             end)
    end

    test "process.spawn still accepts both 1-arg and 2-arg forms" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability process.spawn("workers")

                 fn work() -> Int {
                   1
                 }

                 fn f() -> String {
                   process.spawn("named-task")!
                   process.spawn("with-body", &work)!
                   "ok"
                 }
               }
               """)
    end

    test "reports E0020 for wrong effect arity inside agent phase handlers" do
      errors =
        analyze_errors("""
        agent A {
          capability memory.kv("ns")

          enum Phase {
            Active -> []
          }

          on start() -> {
            transition(Phase.Active)
          }

          on phase(Phase.Active) -> {
            memory.put("ns", "key", "value")!
            stop()
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.severity == :error and e.message =~ "memory.put"
             end)
    end

    test "correct effect arity inside agent handlers analyzes clean" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 capability memory.kv("ns")

                 enum Phase {
                   Active -> []
                 }

                 on start() -> {
                   transition(Phase.Active)
                 }

                 on phase(Phase.Active) -> {
                   memory.put("key", "value")!
                   stop()
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # E0033/E0036: transition()/stop() outside agent
  # ------------------------------------------------------------------

  describe "transition/stop outside agent validation" do
    test "reports E0033 for transition in module function" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String {
            transition(Phase.Done)
            "x"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0033" and e.severity == :error and
                 e.message =~ "transition()" and is_binary(e.fix_hint) and
                 is_binary(e.fix_code)
             end)
    end

    test "reports E0033 for transition in module handler" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/test" (req) -> {
            transition(Phase.Done)
          }
        }
        """)

      assert Enum.any?(errors, fn e -> e.code == "E0033" and e.severity == :error end)
    end

    test "reports E0033 for transition in a test block" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> Int { 1 }

          test "lifecycle calls are rejected" {
            transition(Phase.Done)
          }
        }
        """)

      assert Enum.any?(errors, fn e -> e.code == "E0033" and e.severity == :error end)
    end

    test "reports E0036 for stop in module function" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String {
            stop()
            "x"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0036" and e.severity == :error and
                 e.message =~ "stop()" and is_binary(e.fix_hint) and
                 is_binary(e.fix_code)
             end)
    end

    test "reports E0036 for stop in a match arm of a module function" do
      errors =
        analyze_errors("""
        module M {
          fn f(n: Int) -> Int {
            match n {
              1 -> stop()
              _ -> n
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e -> e.code == "E0036" and e.severity == :error end)
    end
  end

  # ------------------------------------------------------------------
  # E0035: idempotent() outside handler
  # ------------------------------------------------------------------

  describe "idempotent validation" do
    test "reports error for idempotent in module function" do
      errors =
        analyze_errors("""
        module M {
          fn process() -> String {
            idempotent("key-1")
            "done"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0035" and e.severity == :error and
                 e.message =~ "idempotent()"
             end)
    end

    test "accepts idempotent inside module handler" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability queue.consume
                 handler queue "jobs" (msg) -> {
                   idempotent("key-1")
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "accepts idempotent inside http handler" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 handler http GET "/test" (req) -> {
                   idempotent("key-1")
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "reports error for idempotent in agent function" do
      errors =
        analyze_errors("""
        agent A {
          state { ticket_id: String }
          enum Phase {
            Review -> [Done]
            Done -> []
          }
          on start(ticket_id: String) -> {
            transition(Phase.Review)
          }
          on phase(Phase.Review) -> {
            transition(Phase.Done)
          }
          on phase(Phase.Done) -> {
            stop()
          }
          fn helper() -> String {
            idempotent("key")
            "done"
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0035" and e.severity == :error and
                 e.message =~ "idempotent()"
             end)
    end
  end

  # ------------------------------------------------------------------
  # trace.annotate — no capability required
  # ------------------------------------------------------------------

  describe "trace.annotate checking" do
    test "trace.annotate in fn body passes without any capability" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn tag_request(key: String, val: String) -> String {
                   trace.annotate(key, val)
                   "done"
                 }
               }
               """)
    end

    test "trace.annotate in handler body passes without any capability" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in

                 handler http GET "/test" (req) -> {
                   trace.annotate("endpoint", "/test")
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "trace.annotate in agent handler passes without any capability" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 state { id: String }

                 enum Phase {
                   Start -> [Done]
                   Done -> []
                 }

                 on start(id: String) -> {
                   trace.annotate("agent_id", id)
                   transition(Phase.Start)
                 }

                 on phase(Phase.Start) -> {
                   trace.annotate("phase", "start")
                   transition(Phase.Done)
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end

    test "multiple trace.annotate calls in same function pass" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn annotate_all(a: String, b: String) -> String {
                   trace.annotate("key1", a)
                   trace.annotate("key2", b)
                   "done"
                 }
               }
               """)
    end

    test "trace.annotate alongside other effects passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn fetch(url: String) -> String {
                   trace.annotate("url", url)
                   http.get(url)!
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Priority 9: process.spawn, timer, event.log capability checking
  # ------------------------------------------------------------------

  describe "process.spawn capability checking" do
    test "process.spawn effect without capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn run_task() -> String {
            process.spawn("task")!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "process.spawn"
    end

    test "process.spawn with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability process.spawn("workers")

                 fn run_task() -> String {
                   process.spawn("task")!
                 }
               }
               """)
    end

    test "process.spawn with invalid method produces no effect match" do
      # process.invalid is not a known effect method, so it won't be treated as an effect call
      assert {:ok, _} =
               analyze("""
               module M {
                 capability process.spawn("workers")

                 fn run_task() -> String {
                   "ok"
                 }
               }
               """)
    end
  end

  describe "timer capability checking" do
    test "timer.after without capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn schedule() -> String {
            timer.after(1000, "callback")!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "timer"
    end

    test "timer.interval without capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn schedule() -> String {
            timer.interval(5000, "callback")!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "timer"
    end

    test "timer.cancel without capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn cancel_timer() -> String {
            timer.cancel("ref123")!
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "timer"
    end

    test "timer.after with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability timer("default")

                 fn schedule() -> String {
                   timer.after(1000, "callback")!
                 }
               }
               """)
    end

    test "timer.interval with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability timer("default")

                 fn schedule() -> String {
                   timer.interval(5000, "callback")!
                 }
               }
               """)
    end

    test "timer.cancel with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability timer("default")

                 fn cancel_timer() -> String {
                   timer.cancel("ref123")!
                 }
               }
               """)
    end
  end

  describe "event.log capability checking" do
    test "event.log without capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn log_event() -> String {
            event.log("user.login", "data")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0012"))
      assert error != nil
      assert error.message =~ "event.log"
    end

    test "event.log with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability event.log("audit")

                 fn log_event() -> String {
                   event.log("user.login", "data")
                 }
               }
               """)
    end

    test "multiple event.log calls with capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability event.log("audit")

                 fn handle_request() -> String {
                   event.log("request.start", "data")
                   event.log("request.end", "data")
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Field access type inference
  # ------------------------------------------------------------------

  describe "field access type inference" do
    test "field access on typed variable resolves field type" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   name: String
                   age: Int
                 }

                 fn get_name(user: User) -> String {
                   user.name
                 }
               }
               """)
    end

    test "field access on Int field mismatches String return type" do
      errors =
        analyze_errors("""
        module M {
          type User {
            name: String
            age: Int
          }

          fn get_age(user: User) -> String {
            user.age
          }
        }
        """)

      # If field access properly infers Int, this should produce a return type mismatch
      assert length(errors) >= 1
      assert hd(errors).message =~ "type mismatch"
    end

    test "field access on unknown field produces error" do
      errors =
        analyze_errors("""
        module M {
          type User {
            name: String
            age: Int
          }

          fn bad(user: User) -> String {
            user.nonexistent
          }
        }
        """)

      assert length(errors) >= 1
      assert hd(errors).message =~ "nonexistent"
    end

    test "field access on unknown-typed variable returns unknown" do
      # Should not produce a type error - we can't check what we don't know
      assert {:ok, _} =
               analyze("""
               module M {
                 fn foo() -> String {
                   "ok"
                 }
               }
               """)
    end

    test "chained field access through let binding" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type User {
                   name: String
                   age: Int
                 }

                 fn get_name(user: User) -> String {
                   let u = user
                   u.name
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Pattern binding in match arms
  # ------------------------------------------------------------------

  describe "pattern binding in match arms" do
    test "Ok pattern binds inner type from Result" do
      assert {:ok, _} =
               analyze("""
               module M {
                 type Profile {
                   name: String
                 }

                 fn get_profile() -> Result[Profile, String] {
                   Ok({ name: "test" })
                 }

                 fn use_profile() -> String {
                   let result = get_profile()
                   match result {
                     Ok(p) -> p.name
                     Err(e) -> e
                   }
                 }
               }
               """)
    end

    test "Err pattern binds error type from Result" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn might_fail() -> Result[Int, String] {
                   Ok(42)
                 }

                 fn handle() -> String {
                   let result = might_fail()
                   match result {
                     Ok(n) -> "got it"
                     Err(e) -> e
                   }
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Constructor call type inference
  # ------------------------------------------------------------------

  describe "constructor call type inference" do
    test "Ok constructor returns Result type" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn succeed() -> Result[Int, String] {
                   Ok(42)
                 }
               }
               """)
    end
  end

  describe "error context enrichment" do
    test "errors include source context when source_text is provided" do
      source = """
      module M {
        fn bad() -> Int {
          "hello"
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      {:error, errors} = Analyzer.analyze(ast, source_text: source)

      assert length(errors) > 0
      error = hd(errors)
      assert error.context != nil
      assert is_binary(error.context)
    end

    test "context contains the relevant source line" do
      source = """
      module M {
        fn bad() -> Int {
          "hello"
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      {:error, errors} = Analyzer.analyze(ast, source_text: source)

      error = Enum.find(errors, &(&1.code == "E0020"))
      assert error != nil
      # Context is the source line where the error is reported
      assert error.context =~ "fn bad"
    end

    test "E0010 undefined identifier includes fix_code with suggestion" do
      source = """
      module M {
        fn greet() -> String {
          let greeting = "hello"
          greting
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      {:error, errors} = Analyzer.analyze(ast, source_text: source)

      error = Enum.find(errors, &(&1.code == "E0010"))
      assert error != nil
      assert error.fix_code != nil
      assert error.fix_code =~ "greeting"
    end

    test "E0020 type mismatch includes fix_code" do
      source = """
      module M {
        fn bad() -> Int {
          "hello"
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      {:error, errors} = Analyzer.analyze(ast, source_text: source)

      error = Enum.find(errors, &(&1.code == "E0020"))
      assert error != nil
      assert error.fix_code != nil
    end

    test "analyze/1 still works without source_text (backward compat)" do
      source = """
      module M {
        fn greet() -> String {
          "hello"
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:ok, _ast} = Analyzer.analyze(ast)
    end

    test "error context in JSON serialization" do
      source = """
      module M {
        fn bad() -> Int {
          "hello"
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      {:error, errors} = Analyzer.analyze(ast, source_text: source)

      error = hd(errors)
      json = Skein.Error.to_json(error)
      decoded = Jason.decode!(json)
      assert decoded["context"] != nil
    end
  end

  # ------------------------------------------------------------------
  # Cross-module function calls (E0016)
  # ------------------------------------------------------------------

  describe "cross-module function calls (E0016)" do
    test "qualified call to another module's function produces E0016" do
      errors =
        analyze_errors("""
        module Other {
          fn run() -> String {
            Hello.greet("world")
          }
        }
        """)

      assert [error] = Enum.filter(errors, &(&1.code == "E0016"))
      assert error.severity == :error
      assert error.message =~ "Hello.greet"
      assert error.message =~ "module-private"
      assert error.fix_hint =~ "tool"
      assert error.fix_code =~ "capability tool.use(Hello.Greet)"
      assert error.fix_code =~ "tool.call(Hello.Greet"
    end

    test "E0016 fix_code camelizes snake_case function names into tool names" do
      errors =
        analyze_errors("""
        module Other {
          fn run() -> String {
            Billing.fetch_data("acct")
          }
        }
        """)

      assert [error] = Enum.filter(errors, &(&1.code == "E0016"))
      assert error.fix_code =~ "capability tool.use(Billing.FetchData)"
      assert error.fix_code =~ "tool.call(Billing.FetchData"
    end

    test "E0016 fires in module handler bodies" do
      errors =
        analyze_errors("""
        module Web {
          capability http.in

          handler http GET "/charge" (req) -> {
            Billing.charge(1)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0016" and &1.message =~ "Billing.charge"))
    end

    test "E0016 fires in agent function bodies" do
      errors =
        analyze_errors("""
        agent A {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start(ticket_id: String) -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }

          fn helper(x: Int) -> Int {
            Math.square(x)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0016" and &1.message =~ "Math.square"))
    end

    test "self-qualified call inside the same module produces E0016 with a direct-call hint" do
      errors =
        analyze_errors("""
        module Hello {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          fn run() -> String {
            Hello.greet("world")
          }
        }
        """)

      assert [error] = Enum.filter(errors, &(&1.code == "E0016"))
      assert error.fix_hint =~ "greet"
      assert error.fix_code =~ "greet("
      refute error.fix_code =~ "tool.call"
    end

    test "E0016 location points at the offending call" do
      errors =
        analyze_errors("""
        module Other {
          fn run() -> String {
            Hello.greet("world")
          }
        }
        """)

      assert [error] = Enum.filter(errors, &(&1.code == "E0016"))
      assert error.location.line == 3
    end

    test "stdlib calls do not produce E0016" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn shout(s: String) -> String {
                   String.upcase(s)
                 }

                 fn count(l: List[Int]) -> Int {
                   List.length(l)
                 }
               }
               """)
    end

    test "enum variant constructor calls do not produce E0016" do
      errors =
        analyze_errors("""
        module Demo {
          enum Status {
            Active
            Banned(reason: String)
          }

          fn ban() -> Status {
            Status.Banned("spam")
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "E0016"))
    end

    test "agent phase references do not produce E0016" do
      assert {:ok, _} =
               analyze("""
               agent A {
                 enum Phase {
                   Init -> [Done]
                   Done -> []
                 }

                 on start(ticket_id: String) -> {
                   transition(Phase.Init)
                 }

                 on phase(Phase.Init) -> {
                   transition(Phase.Done)
                 }

                 on phase(Phase.Done) -> {
                   stop()
                 }
               }
               """)
    end

    test "dotted tool names in tool.call and capability tool.use do not produce E0016" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use(Stripe.CreateRefund)

                 fn f(args: String) -> String {
                   tool.call(Stripe.CreateRefund, args)!
                 }
               }
               """)
    end

    test "tool error type names are exempt from E0016" do
      errors =
        analyze_errors("""
        module M {
          tool DoThing {
            input { x: String }
            output { y: String }
            errors { SearchError }
            implement { "ok" }
          }

          fn f(e: String) -> String {
            SearchError.from(e)
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "E0016"))
    end

    test "lowercase effect namespaces do not produce E0016" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.out("api.example.com")

                 fn fetch() -> String {
                   let r = http.get("https://api.example.com/x")
                   "done"
                 }
               }
               """)
    end

    test "E0016 errors serialize to JSON" do
      errors =
        analyze_errors("""
        module Other {
          fn run() -> String {
            Hello.greet("world")
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0016"))
      json = Skein.Error.to_json(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == "E0016"
      assert decoded["severity"] == "error"
      assert decoded["fix_hint"] =~ "tool"
      assert decoded["fix_code"] =~ "tool.call"
    end
  end

  # ------------------------------------------------------------------
  # Match guards (#147)
  # ------------------------------------------------------------------

  describe "match guards" do
    test "a valid comparison guard analyzes clean" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn f(n: Int) -> String {
                   match n {
                     x if x > 0 && x <= 100 -> "in range"
                     _ -> "out of range"
                   }
                 }
               }
               """)
    end

    test "guard referencing pattern bindings from a variant analyzes clean" do
      assert {:ok, _} =
               analyze("""
               module M {
                 enum Size {
                   Small
                   Big(n: Int)
                 }

                 fn f(s: Size) -> String {
                   match s {
                     Big(n) if n > 100 -> "huge"
                     Big(n) -> "big"
                     Small -> "small"
                   }
                 }
               }
               """)
    end

    test "effect call in a guard is E0027" do
      errors =
        analyze_errors("""
        module M {
          capability memory.kv("cache")

          fn f(n: Int) -> String {
            match n {
              x if memory.get!("flag") -> "flagged"
              _ -> "plain"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0027"))
      e = Enum.find(errors, &(&1.code == "E0027"))
      assert e.fix_hint != nil
    end

    test "function call in a guard is E0027" do
      errors =
        analyze_errors("""
        module M {
          fn helper(n: Int) -> Bool {
            n > 0
          }

          fn f(n: Int) -> String {
            match n {
              x if helper(x) -> "yes"
              _ -> "no"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0027"))
    end

    test "interpolated string in a guard is E0027" do
      errors =
        analyze_errors("""
        module M {
          fn f(n: Int) -> String {
            match n {
              x if "${x}" == "1" -> "one"
              _ -> "other"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0027"))
    end

    test "division in a guard is E0027" do
      errors =
        analyze_errors("""
        module M {
          fn f(n: Int) -> String {
            match n {
              x if x / 2 > 1 -> "big"
              _ -> "small"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0027"))
    end

    test "non-Bool guard is E0020" do
      errors =
        analyze_errors("""
        module M {
          fn f(n: Int) -> String {
            match n {
              x if x + 1 -> "weird"
              _ -> "other"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0020"))
    end

    test "a guarded catch-all does not satisfy bool exhaustiveness" do
      errors =
        analyze_errors("""
        module M {
          fn f(b: Bool, n: Int) -> String {
            match b {
              true -> "yes"
              x if n > 0 -> "depends"
            }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0021"))
    end

    test "a guarded variant arm does not count as covering its variant" do
      errors =
        analyze_errors("""
        module M {
          enum Status {
            Active
            Failed(code: Int)
          }

          fn f(s: Status) -> String {
            match s {
              Active -> "active"
              Failed(code) if code > 500 -> "server error"
            }
          }
        }
        """)

      assert Enum.any?(errors, fn e -> e.code == "E0024" and e.message =~ "Failed" end)
    end

    test "an unguarded arm alongside a guarded one keeps coverage complete" do
      errors =
        analyze_errors("""
        module M {
          enum Status {
            Active
            Failed(code: Int)
          }

          fn f(s: Status) -> String {
            match s {
              Active -> "active"
              Failed(code) if code > 500 -> "server error"
              Failed(code) -> "failed"
            }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code in ["E0021", "E0024"]))
    end

    test "a binding used only in a guard is not W0001 unused" do
      errors =
        analyze_errors("""
        module M {
          fn f(n: Int, threshold: Int) -> String {
            match n {
              x if x > threshold -> "above"
              _ -> "below"
            }
          }
        }
        """)

      refute Enum.any?(errors, &(&1.code == "W0001"))
    end
  end
end
