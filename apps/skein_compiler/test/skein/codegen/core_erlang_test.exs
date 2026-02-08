defmodule Skein.CodeGen.CoreErlangTest do
  use ExUnit.Case, async: false

  alias Skein.Compiler

  # Helper: compile a Skein source string and return the loaded module
  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # Helper: same as compile! but for modules with capabilities and effect calls
  defp compile_with_caps!(source) do
    compile!(source)
  end

  describe "Phase 1 acceptance - hello.skein" do
    test "greet/1 returns interpolated greeting" do
      mod =
        compile!("""
        module HelloGreet {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }
        }
        """)

      assert mod.greet("World") == "Hello, World!"
      assert mod.greet("Skein") == "Hello, Skein!"
      assert mod.greet("") == "Hello, !"
    end

    test "add/2 returns the sum of two integers" do
      mod =
        compile!("""
        module HelloAdd {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }
        }
        """)

      assert mod.add(3, 4) == 7
      assert mod.add(0, 0) == 0
      assert mod.add(-1, 1) == 0
      assert mod.add(100, 200) == 300
    end

    test "classify/1 returns correct classification" do
      mod =
        compile!("""
        module HelloClassify {
          fn classify(n: Int) -> String {
            match n > 0 {
              true  -> "positive"
              false -> "non-positive"
            }
          }
        }
        """)

      assert mod.classify(5) == "positive"
      assert mod.classify(1) == "positive"
      assert mod.classify(0) == "non-positive"
      assert mod.classify(-1) == "non-positive"
      assert mod.classify(-100) == "non-positive"
    end

    test "all three functions in one module" do
      mod =
        compile!("""
        module HelloAll {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn classify(n: Int) -> String {
            match n > 0 {
              true  -> "positive"
              false -> "non-positive"
            }
          }
        }
        """)

      assert mod.greet("World") == "Hello, World!"
      assert mod.add(3, 4) == 7
      assert mod.classify(5) == "positive"
      assert mod.classify(-1) == "non-positive"
    end
  end

  describe "integer arithmetic" do
    test "subtraction" do
      mod =
        compile!("""
        module ArithSub {
          fn sub(a: Int, b: Int) -> Int {
            a - b
          }
        }
        """)

      assert mod.sub(10, 3) == 7
    end

    test "multiplication" do
      mod =
        compile!("""
        module ArithMul {
          fn mul(a: Int, b: Int) -> Int {
            a * b
          }
        }
        """)

      assert mod.mul(6, 7) == 42
    end

    test "integer division" do
      mod =
        compile!("""
        module ArithDiv {
          fn divide(a: Int, b: Int) -> Int {
            a / b
          }
        }
        """)

      assert mod.divide(10, 3) == 3
      assert mod.divide(9, 3) == 3
    end

    test "complex expression with precedence" do
      mod =
        compile!("""
        module ArithComplex {
          fn calc(a: Int, b: Int, c: Int) -> Int {
            a + b * c
          }
        }
        """)

      # Should compute a + (b * c), not (a + b) * c
      assert mod.calc(1, 2, 3) == 7
    end
  end

  describe "let bindings" do
    test "simple let binding" do
      mod =
        compile!("""
        module LetSimple {
          fn double(x: Int) -> Int {
            let result = x + x
            result
          }
        }
        """)

      assert mod.double(5) == 10
    end

    test "multiple let bindings" do
      mod =
        compile!("""
        module LetMulti {
          fn calc(x: Int) -> Int {
            let a = x + 1
            let b = a + 2
            b
          }
        }
        """)

      assert mod.calc(10) == 13
    end
  end

  describe "boolean operations" do
    test "comparison operators" do
      mod =
        compile!("""
        module BoolCmp {
          fn is_positive(n: Int) -> Bool {
            n > 0
          }

          fn is_zero(n: Int) -> Bool {
            n == 0
          }
        }
        """)

      assert mod.is_positive(1) == true
      assert mod.is_positive(0) == false
      assert mod.is_zero(0) == true
      assert mod.is_zero(1) == false
    end
  end

  describe "string operations" do
    test "plain string literal" do
      mod =
        compile!("""
        module StrPlain {
          fn hello() -> String {
            "hello world"
          }
        }
        """)

      assert mod.hello() == "hello world"
    end

    test "string with multiple interpolations" do
      mod =
        compile!("""
        module StrMulti {
          fn greet(first: String, last: String) -> String {
            "${first} ${last}"
          }
        }
        """)

      assert mod.greet("Jane", "Doe") == "Jane Doe"
    end
  end

  describe "match expressions" do
    test "match on integer values" do
      mod =
        compile!("""
        module MatchInt {
          fn describe(n: Int) -> String {
            match n {
              0 -> "zero"
              1 -> "one"
              _ -> "other"
            }
          }
        }
        """)

      assert mod.describe(0) == "zero"
      assert mod.describe(1) == "one"
      assert mod.describe(42) == "other"
    end

    test "match on boolean with block body" do
      mod =
        compile!("""
        module MatchBlock {
          fn abs_val(n: Int) -> Int {
            match n > 0 {
              true -> n
              false -> 0 - n
            }
          }
        }
        """)

      assert mod.abs_val(5) == 5
      assert mod.abs_val(-3) == 3
      assert mod.abs_val(0) == 0
    end
  end

  describe "compile_file/1" do
    test "compiles a .skein file" do
      assert {:module, mod} = Compiler.compile_file("../../examples/hello.skein")
      assert mod.greet("World") == "Hello, World!"
      assert mod.add(3, 4) == 7
      assert mod.classify(5) == "positive"
    end
  end

  # ------------------------------------------------------------------
  # Phase 3: Capability metadata and effect call codegen
  # ------------------------------------------------------------------

  describe "__capabilities__/0" do
    test "module with no capabilities returns empty list" do
      mod =
        compile!("""
        module CapEmpty {
          fn x() -> Int { 1 }
        }
        """)

      assert mod.__capabilities__() == []
    end

    test "module with http.out capability returns it" do
      mod =
        compile_with_caps!("""
        module CapHttp {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "http.out", params: ["api.example.com"]} = hd(caps)
    end

    test "module with multiple capabilities returns all" do
      mod =
        compile_with_caps!("""
        module CapMulti {
          capability http.out("api.example.com")
          capability http.out("api.other.com")

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 2
    end

    test "capability without params returns empty params list" do
      mod =
        compile_with_caps!("""
        module CapNoParams {
          capability http.out

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "http.out", params: []} = hd(caps)
    end
  end

  describe "effect call codegen" do
    test "http.get compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module EffectGet {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # The function should exist and be callable
      fns = mod.__info__(:functions)
      assert {:fetch, 1} in fns
    end

    test "http.post compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module EffectPost {
          capability http.out("api.example.com")

          fn send(url: String, body: String) -> String {
            http.post(url, body)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:send, 2} in fns
    end

    test "http.get at runtime enforces capabilities - blocks undeclared host" do
      mod =
        compile_with_caps!("""
        module EffectBlock {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # Calling with an undeclared host should return capability error
      result = mod.fetch("https://api.blocked.com/data")
      assert {:error, reason} = result
      assert reason =~ "not declared"
    end

    test "http.get at runtime enforces capabilities - allows declared host" do
      mod =
        compile_with_caps!("""
        module EffectAllow {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # Calling with a declared host - will attempt HTTP (may fail to connect,
      # but should NOT be a capability error)
      result = mod.fetch("https://api.example.com/data")

      case result do
        {:error, reason} -> refute reason =~ "not declared"
        {:ok, _} -> :ok
      end
    end

    test "http.get records trace span" do
      Skein.Runtime.Trace.clear()

      mod =
        compile_with_caps!("""
        module EffectTrace {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # This will be blocked by capability, but should still trace
      mod.fetch("https://api.blocked.com/data")

      spans = Skein.Runtime.Trace.recent_spans(10)
      assert length(spans) >= 1

      span = hd(spans)
      assert span.kind == :http
      assert span.method == :get
      assert span.url == "https://api.blocked.com/data"
      assert is_integer(span.duration_us)
    end

    test "effect call in let binding works" do
      mod =
        compile_with_caps!("""
        module EffectLet {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            let result = http.get(url)
            result
          }
        }
        """)

      result = mod.fetch("https://api.blocked.com/data")
      assert {:error, reason} = result
      assert reason =~ "not declared"
    end
  end

  describe "__info__/1 Elixir interop" do
    test "module responds to __info__(:module)" do
      mod =
        compile!("""
        module InfoTest {
          fn x() -> Int { 1 }
        }
        """)

      assert mod.__info__(:module) == mod
    end

    test "module responds to __info__(:functions)" do
      mod =
        compile!("""
        module InfoFns {
          fn a() -> Int { 1 }
          fn b(x: Int) -> Int { x }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:a, 0} in fns
      assert {:b, 1} in fns
    end
  end
end
