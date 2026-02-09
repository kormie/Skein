defmodule Skein.StdlibTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Compiler

  # Helper: compile a Skein source string and return the loaded module
  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  defp analyze(source) do
    {:ok, tokens} = Skein.Lexer.tokenize(source)
    {:ok, ast} = Skein.Parser.parse(tokens)
    Skein.Analyzer.analyze(ast)
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  # ---------------------------------------------------------------
  # String stdlib
  # ---------------------------------------------------------------
  describe "String.length" do
    test "returns length of a string" do
      mod =
        compile!("""
        module StrLen {
          fn len(s: String) -> Int {
            String.length(s)
          }
        }
        """)

      assert mod.len("hello") == 5
      assert mod.len("") == 0
      assert mod.len("abc") == 3
    end

    test "analyzes with correct types" do
      assert {:ok, _} =
               analyze("""
               module StrLen {
                 fn len(s: String) -> Int {
                   String.length(s)
                 }
               }
               """)
    end
  end

  describe "String.slice" do
    test "extracts substring" do
      mod =
        compile!("""
        module StrSlice {
          fn sub(s: String, start: Int, len: Int) -> String {
            String.slice(s, start, len)
          }
        }
        """)

      assert mod.sub("hello world", 0, 5) == "hello"
      assert mod.sub("hello world", 6, 5) == "world"
      assert mod.sub("abc", 1, 1) == "b"
    end
  end

  describe "String.contains" do
    test "checks containment" do
      mod =
        compile!("""
        module StrContains {
          fn has(s: String, sub: String) -> Bool {
            String.contains(s, sub)
          }
        }
        """)

      assert mod.has("hello world", "world") == true
      assert mod.has("hello world", "xyz") == false
      assert mod.has("abc", "") == true
    end
  end

  describe "String.split" do
    test "splits string by delimiter" do
      mod =
        compile!("""
        module StrSplit {
          fn parts(s: String, delim: String) -> List[String] {
            String.split(s, delim)
          }
        }
        """)

      assert mod.parts("a,b,c", ",") == ["a", "b", "c"]
      assert mod.parts("hello", " ") == ["hello"]
      assert mod.parts("a::b", "::") == ["a", "b"]
    end
  end

  describe "String.trim" do
    test "removes surrounding whitespace" do
      mod =
        compile!("""
        module StrTrim {
          fn clean(s: String) -> String {
            String.trim(s)
          }
        }
        """)

      assert mod.clean("  hello  ") == "hello"
      assert mod.clean("hello") == "hello"
      assert mod.clean("  ") == ""
    end
  end

  describe "String.upcase" do
    test "converts to uppercase" do
      mod =
        compile!("""
        module StrUp {
          fn up(s: String) -> String {
            String.upcase(s)
          }
        }
        """)

      assert mod.up("hello") == "HELLO"
      assert mod.up("Hello World") == "HELLO WORLD"
      assert mod.up("") == ""
    end
  end

  describe "String.downcase" do
    test "converts to lowercase" do
      mod =
        compile!("""
        module StrDown {
          fn down(s: String) -> String {
            String.downcase(s)
          }
        }
        """)

      assert mod.down("HELLO") == "hello"
      assert mod.down("Hello World") == "hello world"
      assert mod.down("") == ""
    end
  end

  describe "String.starts_with" do
    test "checks prefix" do
      mod =
        compile!("""
        module StrStarts {
          fn prefix(s: String, pre: String) -> Bool {
            String.starts_with(s, pre)
          }
        }
        """)

      assert mod.prefix("hello world", "hello") == true
      assert mod.prefix("hello world", "world") == false
      assert mod.prefix("abc", "") == true
    end
  end

  describe "String.ends_with" do
    test "checks suffix" do
      mod =
        compile!("""
        module StrEnds {
          fn suffix(s: String, suf: String) -> Bool {
            String.ends_with(s, suf)
          }
        }
        """)

      assert mod.suffix("hello world", "world") == true
      assert mod.suffix("hello world", "hello") == false
      assert mod.suffix("abc", "") == true
    end
  end

  describe "String.replace" do
    test "replaces pattern with replacement" do
      mod =
        compile!("""
        module StrReplace {
          fn sub(s: String, pat: String, rep: String) -> String {
            String.replace(s, pat, rep)
          }
        }
        """)

      assert mod.sub("hello world", "world", "skein") == "hello skein"
      assert mod.sub("aaa", "a", "b") == "bbb"
      assert mod.sub("abc", "x", "y") == "abc"
    end
  end

  # ---------------------------------------------------------------
  # Int stdlib
  # ---------------------------------------------------------------
  describe "Int.parse" do
    test "parses valid integer strings" do
      mod =
        compile!("""
        module IntParse {
          fn parse(s: String) -> Result[Int, String] {
            Int.parse(s)
          }
        }
        """)

      assert mod.parse("42") == {:ok, 42}
      assert mod.parse("-7") == {:ok, -7}
      assert mod.parse("0") == {:ok, 0}
    end

    test "returns error for invalid strings" do
      mod =
        compile!("""
        module IntParseFail {
          fn parse(s: String) -> Result[Int, String] {
            Int.parse(s)
          }
        }
        """)

      assert {:error, _} = mod.parse("abc")
      assert {:error, _} = mod.parse("")
      assert {:error, _} = mod.parse("3.14")
    end
  end

  describe "Int.to_string" do
    test "converts integers to strings" do
      mod =
        compile!("""
        module IntStr {
          fn show(n: Int) -> String {
            Int.to_string(n)
          }
        }
        """)

      assert mod.show(42) == "42"
      assert mod.show(0) == "0"
      assert mod.show(-7) == "-7"
    end
  end

  describe "Int.abs" do
    test "returns absolute value" do
      mod =
        compile!("""
        module IntAbs {
          fn absolute(n: Int) -> Int {
            Int.abs(n)
          }
        }
        """)

      assert mod.absolute(5) == 5
      assert mod.absolute(-5) == 5
      assert mod.absolute(0) == 0
    end
  end

  describe "Int.min" do
    test "returns minimum of two ints" do
      mod =
        compile!("""
        module IntMin {
          fn smallest(a: Int, b: Int) -> Int {
            Int.min(a, b)
          }
        }
        """)

      assert mod.smallest(3, 5) == 3
      assert mod.smallest(5, 3) == 3
      assert mod.smallest(4, 4) == 4
    end
  end

  describe "Int.max" do
    test "returns maximum of two ints" do
      mod =
        compile!("""
        module IntMax {
          fn largest(a: Int, b: Int) -> Int {
            Int.max(a, b)
          }
        }
        """)

      assert mod.largest(3, 5) == 5
      assert mod.largest(5, 3) == 5
      assert mod.largest(4, 4) == 4
    end
  end

  describe "Int.clamp" do
    test "clamps value between bounds" do
      mod =
        compile!("""
        module IntClamp {
          fn bound(n: Int, low: Int, high: Int) -> Int {
            Int.clamp(n, low, high)
          }
        }
        """)

      assert mod.bound(5, 1, 10) == 5
      assert mod.bound(0, 1, 10) == 1
      assert mod.bound(15, 1, 10) == 10
      assert mod.bound(1, 1, 10) == 1
      assert mod.bound(10, 1, 10) == 10
    end
  end

  # ---------------------------------------------------------------
  # Float stdlib
  # ---------------------------------------------------------------
  describe "Float.parse" do
    test "parses valid float strings" do
      mod =
        compile!("""
        module FloatParse {
          fn parse(s: String) -> Result[Float, String] {
            Float.parse(s)
          }
        }
        """)

      assert mod.parse("3.14") == {:ok, 3.14}
      assert mod.parse("-2.5") == {:ok, -2.5}
      assert mod.parse("0.0") == {:ok, 0.0}
    end

    test "returns error for invalid strings" do
      mod =
        compile!("""
        module FloatParseFail {
          fn parse(s: String) -> Result[Float, String] {
            Float.parse(s)
          }
        }
        """)

      assert {:error, _} = mod.parse("abc")
      assert {:error, _} = mod.parse("")
    end
  end

  describe "Float.to_string" do
    test "converts floats to strings" do
      mod =
        compile!("""
        module FloatStr {
          fn show(f: Float) -> String {
            Float.to_string(f)
          }
        }
        """)

      result = mod.show(3.14)
      assert is_binary(result)
      assert result =~ "3.14"
    end
  end

  describe "Float.round" do
    test "rounds to specified decimal places" do
      mod =
        compile!("""
        module FloatRound {
          fn rnd(f: Float, decimals: Int) -> Float {
            Float.round(f, decimals)
          }
        }
        """)

      assert mod.rnd(3.14159, 2) == 3.14
      assert mod.rnd(2.5, 0) == 3.0
      assert mod.rnd(1.005, 2) == 1.0
    end
  end

  describe "Float.ceil" do
    test "returns ceiling as integer" do
      mod =
        compile!("""
        module FloatCeil {
          fn up(f: Float) -> Int {
            Float.ceil(f)
          }
        }
        """)

      assert mod.up(3.2) == 4
      assert mod.up(3.0) == 3
      assert mod.up(-1.5) == -1
    end
  end

  describe "Float.floor" do
    test "returns floor as integer" do
      mod =
        compile!("""
        module FloatFloor {
          fn down(f: Float) -> Int {
            Float.floor(f)
          }
        }
        """)

      assert mod.down(3.7) == 3
      assert mod.down(3.0) == 3
      assert mod.down(-1.5) == -2
    end
  end

  # ---------------------------------------------------------------
  # Analyzer: type checking stdlib calls
  # ---------------------------------------------------------------
  describe "analyzer type checking for stdlib calls" do
    test "String.length with non-string arg produces type error" do
      errors =
        analyze_errors("""
        module Bad {
          fn bad() -> Int {
            String.length(42)
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, fn e -> e.code == "E0020" end)
    end

    test "Int.abs with wrong arity produces error" do
      errors =
        analyze_errors("""
        module Bad {
          fn bad() -> Int {
            Int.abs(1, 2)
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, fn e -> e.code == "E0012" end)
    end

    test "unknown stdlib function produces error" do
      errors =
        analyze_errors("""
        module Bad {
          fn bad() -> Int {
            String.nonexistent("hello")
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, fn e -> e.code == "E0010" end)
    end

    test "stdlib call return type mismatch produces error" do
      errors =
        analyze_errors("""
        module Bad {
          fn bad() -> String {
            Int.abs(5)
          }
        }
        """)

      assert length(errors) >= 1
      assert Enum.any?(errors, fn e -> e.code == "E0020" end)
    end
  end

  # ---------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------
  describe "String stdlib properties" do
    property "String.length returns non-negative integer" do
      mod =
        compile!("""
        module PropStrLen {
          fn len(s: String) -> Int {
            String.length(s)
          }
        }
        """)

      check all(s <- string(:printable)) do
        assert mod.len(s) >= 0
      end
    end

    property "String.trim is idempotent" do
      mod =
        compile!("""
        module PropStrTrim {
          fn clean(s: String) -> String {
            String.trim(s)
          }
        }
        """)

      check all(s <- string(:printable)) do
        assert mod.clean(mod.clean(s)) == mod.clean(s)
      end
    end

    property "String.upcase/downcase round-trip preserves length" do
      mod =
        compile!("""
        module PropStrCase {
          fn up(s: String) -> String {
            String.upcase(s)
          }
          fn down(s: String) -> String {
            String.downcase(s)
          }
          fn len(s: String) -> Int {
            String.length(s)
          }
        }
        """)

      check all(s <- string(:ascii)) do
        assert mod.len(mod.up(s)) == mod.len(s)
        assert mod.len(mod.down(s)) == mod.len(s)
      end
    end
  end

  describe "Int stdlib properties" do
    property "Int.abs returns non-negative value" do
      mod =
        compile!("""
        module PropIntAbs {
          fn absolute(n: Int) -> Int {
            Int.abs(n)
          }
        }
        """)

      check all(n <- integer()) do
        assert mod.absolute(n) >= 0
      end
    end

    property "Int.min(a, b) <= Int.max(a, b)" do
      mod =
        compile!("""
        module PropIntMinMax {
          fn smallest(a: Int, b: Int) -> Int {
            Int.min(a, b)
          }
          fn largest(a: Int, b: Int) -> Int {
            Int.max(a, b)
          }
        }
        """)

      check all(a <- integer(), b <- integer()) do
        assert mod.smallest(a, b) <= mod.largest(a, b)
      end
    end

    property "Int.clamp result is within bounds" do
      mod =
        compile!("""
        module PropIntClamp {
          fn bound(n: Int, low: Int, high: Int) -> Int {
            Int.clamp(n, low, high)
          }
        }
        """)

      check all(
              n <- integer(),
              low <- integer(-100..0),
              high <- integer(0..100),
              low <= high
            ) do
        result = mod.bound(n, low, high)
        assert result >= low
        assert result <= high
      end
    end

    property "Int.parse round-trips with Int.to_string" do
      mod =
        compile!("""
        module PropIntRoundTrip {
          fn show(n: Int) -> String {
            Int.to_string(n)
          }
          fn parse(s: String) -> Result[Int, String] {
            Int.parse(s)
          }
        }
        """)

      check all(n <- integer()) do
        assert mod.parse(mod.show(n)) == {:ok, n}
      end
    end
  end

  describe "Float stdlib properties" do
    property "Float.ceil(f) >= f" do
      mod =
        compile!("""
        module PropFloatCeil {
          fn up(f: Float) -> Int {
            Float.ceil(f)
          }
        }
        """)

      check all(f <- float(min: -1_000_000.0, max: 1_000_000.0)) do
        assert mod.up(f) >= f
      end
    end

    property "Float.floor(f) <= f" do
      mod =
        compile!("""
        module PropFloatFloor {
          fn down(f: Float) -> Int {
            Float.floor(f)
          }
        }
        """)

      check all(f <- float(min: -1_000_000.0, max: 1_000_000.0)) do
        assert mod.down(f) <= f
      end
    end
  end

  # ---------------------------------------------------------------
  # Integration: stdlib in let bindings and pipelines
  # ---------------------------------------------------------------
  describe "stdlib in expressions" do
    test "stdlib call in let binding" do
      mod =
        compile!("""
        module StdlibLet {
          fn process(s: String) -> String {
            let upper = String.upcase(s)
            let trimmed = String.trim(upper)
            trimmed
          }
        }
        """)

      assert mod.process("  hello  ") == "HELLO"
    end

    test "multiple stdlib modules in one function" do
      mod =
        compile!("""
        module StdlibMulti {
          fn format_number(n: Int) -> String {
            let abs_val = Int.abs(n)
            Int.to_string(abs_val)
          }
        }
        """)

      assert mod.format_number(-42) == "42"
      assert mod.format_number(7) == "7"
    end
  end
end
