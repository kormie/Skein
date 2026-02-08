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

  # ------------------------------------------------------------------
  # Capability checking (Phase 3)
  # ------------------------------------------------------------------

  describe "capability checking - missing capabilities" do
    test "http.get without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0030"))
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
            http.post(url, body)
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "http.out"
    end

    test "http.put without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn update(url: String, body: String) -> String {
            http.put(url, body)
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, &(&1.code == "E0030"))
    end

    test "http.delete without capability http.out produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(url: String) -> String {
            http.delete(url)
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, &(&1.code == "E0030"))
    end

    test "error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error.fix_code != nil
      assert error.fix_code =~ "capability http.out"
    end

    test "error includes fix_hint" do
      errors =
        analyze_errors("""
        module M {
          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
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
                   http.get(url)
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
                   http.post(url, body)
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
                   http.get(url)
                 }

                 fn send(url: String, body: String) -> String {
                   http.post(url, body)
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
                   http.get(url)
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

      assert Enum.any?(errors, &(&1.code == "E0030"))
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

      assert Enum.any?(errors, &(&1.code == "E0030"))
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

      assert Enum.any?(errors, &(&1.code == "E0030"))
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

      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))
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
      error = Enum.find(errors, &(&1.code == "E0030"))
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

      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))
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
            http.get("https://example.com")
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030" and &1.message =~ "http.out"))
    end

    test "handler with both http.in and http.out capabilities passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability http.out("example.com")

                 handler http GET "/proxy" (req) -> {
                   http.get("https://example.com/data")
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
            store.users.get(id)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "store.table"
      assert error.message =~ "users"
    end

    test "store.users.put without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn save(record: String) -> String {
            store.users.put(record)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "store.table"
      assert error.message =~ "users"
    end

    test "store.users.delete without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(id: Uuid) -> String {
            store.users.delete(id)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "store.table"
    end

    test "store.users.query without store.table capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn search(email: String) -> String {
            store.users.query(email)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
    end

    test "store error includes fix_code with table name" do
      errors =
        analyze_errors("""
        module M {
          fn find(id: Uuid) -> String {
            store.orders.get(id)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error.fix_code == "capability store.table(\"orders\")"
    end

    test "wrong table name still produces error" do
      errors =
        analyze_errors("""
        module M {
          capability store.table("users")

          fn find(id: Uuid) -> String {
            store.orders.get(id)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
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
                   store.users.get(id)
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
                   store.users.put(record)
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
                   store.users.get(id)
                 }

                 fn find_order(id: Uuid) -> String {
                   store.orders.get(id)
                 }
               }
               """)
    end

    test "multiple store methods on the same table pass with one capability" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability store.table("items")

                 fn crud(id: Uuid) -> String {
                   store.items.get(id)
                   store.items.put(id)
                   store.items.delete(id)
                   store.items.query(id)
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
            http.get(url)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      json = Skein.Error.to_json(error)
      decoded = Jason.decode!(json)
      assert decoded["code"] == "E0030"
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

      assert Enum.any?(errors, &(&1.code == "E0011" and &1.message =~ "UnknownType"))
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
  # Memory capability checking
  # ------------------------------------------------------------------

  describe "memory capability checking - missing capabilities" do
    test "memory.put without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.get without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn load(key: String) -> String {
            memory.get(key)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.delete without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn remove(key: String) -> String {
            memory.delete(key)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory.list without memory.kv capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn keys(prefix: String) -> String {
            memory.list(prefix)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "memory.kv"
    end

    test "memory error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
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
                   memory.put(key, value)
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
                   memory.get(key)
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
                   memory.put(key, "value")
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
                   memory.put(key, value)
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
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm.json without model capability produces error" do
      errors =
        analyze_errors("""
        module M {
          fn decide(data: String) -> String {
            llm.json("claude-sonnet-4-5", "Return JSON.", data)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm error includes fix_code with capability declaration" do
      errors =
        analyze_errors("""
        module M {
          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
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
                   llm.chat("claude-sonnet-4-5", "Be helpful.", data)
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
                   llm.json("claude-sonnet-4-5", "Return JSON.", data)
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
            llm.stream("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "model"
    end

    test "llm.stream with model capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability model("anthropic", "claude-sonnet-4-5")

                 fn stream_it(data: String) -> String {
                   llm.stream("claude-sonnet-4-5", "Be helpful.", data)
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

    test "tool with unknown input type produces E0011" do
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

      assert Enum.any?(errors, &(&1.code == "E0011"))
      assert Enum.any?(errors, &String.contains?(&1.message, "Foo"))
    end

    test "tool with unknown output type produces E0011" do
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

      assert Enum.any?(errors, &(&1.code == "E0011"))
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
    test "tool.call without tool.use capability produces E0030" do
      errors =
        analyze_errors("""
        module M {
          fn f(args: String) -> String {
            tool.call("MyTool", args)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030"))
      assert Enum.any?(errors, &String.contains?(&1.message, "tool.use"))
    end

    test "tool.call with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use("MyTool")

                 fn f(args: String) -> String {
                   tool.call("MyTool", args)
                 }
               }
               """)
    end

    test "tool.list without tool.use capability produces E0030" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String {
            tool.list()
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030"))
    end

    test "tool.list with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use("MyTool")

                 fn f() -> String {
                   tool.list()
                 }
               }
               """)
    end

    test "tool.schema without tool.use capability produces E0030" do
      errors =
        analyze_errors("""
        module M {
          fn f() -> String {
            tool.schema("MyTool")
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030"))
    end

    test "tool.schema with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability tool.use("MyTool")

                 fn f() -> String {
                   tool.schema("MyTool")
                 }
               }
               """)
    end

    test "tool.call in handler with tool.use capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability tool.use("MyTool")

                 handler http GET "/test" (req) -> {
                   tool.call("MyTool", req)
                 }
               }
               """)
    end

    test "tool.call in handler without tool.use capability produces E0030" do
      errors =
        analyze_errors("""
        module M {
          capability http.in

          handler http GET "/test" (req) -> {
            tool.call("MyTool", req)
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030"))
    end
  end

  # ------------------------------------------------------------------
  # Queue handler capability checking (Phase 8e)
  # ------------------------------------------------------------------

  describe "queue handler checking - queue.in capability" do
    test "queue handler without queue.in capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler queue "events" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "queue.in"
      assert error.fix_code == "capability queue.in"
    end

    test "queue handler with queue.in capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability queue.in

                 handler queue "events" (msg) -> {
                   respond.json(200, "ok")
                 }
               }
               """)
    end

    test "multiple queue handlers all require queue.in" do
      errors =
        analyze_errors("""
        module M {
          handler queue "a" (msg) -> { respond.json(200, "a") }
          handler queue "b" (msg) -> { respond.json(200, "b") }
        }
        """)

      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))
      assert length(capability_errors) >= 2
    end
  end

  # ------------------------------------------------------------------
  # Schedule handler capability checking (Phase 8e)
  # ------------------------------------------------------------------

  describe "schedule handler checking - schedule.in capability" do
    test "schedule handler without schedule.in capability produces error" do
      errors =
        analyze_errors("""
        module M {
          handler schedule "*/5 * * * *" () -> {
            respond.json(200, "tick")
          }
        }
        """)

      assert length(errors) >= 1
      error = Enum.find(errors, &(&1.code == "E0030"))
      assert error != nil
      assert error.message =~ "schedule.in"
      assert error.fix_code == "capability schedule.in"
    end

    test "schedule handler with schedule.in capability passes" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability schedule.in

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
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))
      assert length(capability_errors) >= 3

      messages = Enum.map(capability_errors, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "http.in"))
      assert Enum.any?(messages, &(&1 =~ "queue.in"))
      assert Enum.any?(messages, &(&1 =~ "schedule.in"))
    end

    test "all capabilities declared passes for mixed handlers" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability http.in
                 capability queue.in
                 capability schedule.in

                 handler http GET "/test" (req) -> { respond.json(200, "ok") }
                 handler queue "events" (msg) -> { respond.json(200, "ok") }
                 handler schedule "*/5 * * * *" () -> { respond.json(200, "ok") }
               }
               """)
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
end
