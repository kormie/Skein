defmodule Skein.CodeGen.CoreErlangPropertyTest do
  @moduledoc """
  Property-based tests for the Skein code generator.

  Generates valid Skein programs, compiles them to BEAM, and verifies
  runtime behaviour matches expectations.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Compiler

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp unique_module_name do
    counter = System.unique_integer([:positive, :monotonic])
    "PropMod#{counter}"
  end

  property "integer addition compiles and computes correctly" do
    check all(
            a <- StreamData.integer(-1000..1000),
            b <- StreamData.integer(-1000..1000)
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.add(a, b) == a + b
    end
  end

  property "integer subtraction compiles and computes correctly" do
    check all(
            a <- StreamData.integer(-1000..1000),
            b <- StreamData.integer(-1000..1000)
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn sub(a: Int, b: Int) -> Int {
          a - b
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.sub(a, b) == a - b
    end
  end

  property "integer multiplication compiles and computes correctly" do
    check all(
            a <- StreamData.integer(-100..100),
            b <- StreamData.integer(-100..100)
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn mul(a: Int, b: Int) -> Int {
          a * b
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.mul(a, b) == a * b
    end
  end

  property "comparison > produces correct boolean" do
    check all(
            a <- StreamData.integer(-1000..1000),
            b <- StreamData.integer(-1000..1000)
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn gt(a: Int, b: Int) -> Bool {
          a > b
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.gt(a, b) == a > b
    end
  end

  property "equality == produces correct boolean" do
    check all(
            a <- StreamData.integer(-1000..1000),
            b <- StreamData.integer(-1000..1000)
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn eq(a: Int, b: Int) -> Bool {
          a == b
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.eq(a, b) == (a == b)
    end
  end

  property "string interpolation round-trips any alphanumeric input" do
    check all(
            name <-
              StreamData.string(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z),
                min_length: 1,
                max_length: 20
              )
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.greet(name) == "Hello, #{name}!"
    end
  end

  property "let binding preserves computed value" do
    check all(n <- StreamData.integer(0..1000)) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn double(x: Int) -> Int {
          let result = x + x
          result
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.double(n) == n + n
    end
  end

  property "match on > 0 correctly classifies positive vs non-positive" do
    check all(n <- StreamData.integer(-1000..1000)) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        fn classify(n: Int) -> String {
          match n > 0 {
            true -> "positive"
            false -> "non-positive"
          }
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      expected = if n > 0, do: "positive", else: "non-positive"
      assert mod.classify(n) == expected
    end
  end

  property "plain string literal returns exact string" do
    check all(
            text <-
              StreamData.string(Enum.to_list(?a..?z) ++ [?\s],
                min_length: 0,
                max_length: 30
              )
          ) do
      mod_name = unique_module_name()
      # Escape any special chars for source embedding
      escaped = String.replace(text, "\\", "\\\\") |> String.replace("\"", "\\\"")

      source = """
      module #{mod_name} {
        fn get_text() -> String {
          "#{escaped}"
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      assert mod.get_text() == text
    end
  end

  # ------------------------------------------------------------------
  # Queue handler property tests (Phase 8e)
  # ------------------------------------------------------------------

  property "queue handler compiles and responds for any alphanumeric queue name" do
    check all(
            queue_name <-
              StreamData.string(Enum.to_list(?a..?z) ++ [?-],
                min_length: 1,
                max_length: 20
              )
          ) do
      mod_name = unique_module_name()

      source = """
      module #{mod_name} {
        capability queue.in

        handler queue "#{queue_name}" (msg) -> {
          respond.json(200, "processed")
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      handlers = mod.__handlers__()
      assert length(handlers) == 1
      assert hd(handlers).source == :queue
      assert hd(handlers).route == queue_name

      result = mod.__handler_0__(%{body: "test"})
      assert {:respond_json, 200, "processed"} = result
    end
  end

  property "schedule handler compiles for standard cron expressions" do
    check all(
            minute <- StreamData.member_of(["*", "*/5", "*/10", "0", "30"]),
            hour <- StreamData.member_of(["*", "0", "6", "12", "23"]),
            day <- StreamData.member_of(["*", "1", "15"]),
            month <- StreamData.member_of(["*", "1", "6", "12"]),
            weekday <- StreamData.member_of(["*", "0", "1", "5"])
          ) do
      mod_name = unique_module_name()
      cron = "#{minute} #{hour} #{day} #{month} #{weekday}"

      source = """
      module #{mod_name} {
        capability schedule.in

        handler schedule "#{cron}" () -> {
          respond.json(200, "tick")
        }
      }
      """

      {:module, mod} = Compiler.compile_string(source)
      handlers = mod.__handlers__()
      assert length(handlers) == 1
      assert hd(handlers).source == :schedule
      assert hd(handlers).route == cron

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "tick"} = result
    end
  end
end
