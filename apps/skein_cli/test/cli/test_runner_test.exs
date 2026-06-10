defmodule Skein.CLI.TestRunnerTest do
  use ExUnit.Case, async: false

  alias Skein.CLI

  @tmp_dir Path.expand("../../tmp/test_runner_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    src_dir = Path.join(@tmp_dir, "src")
    test_dir = Path.join(@tmp_dir, "test")
    File.mkdir_p!(src_dir)
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir, src_dir: src_dir, test_dir: test_dir}
  end

  describe "test_all/1 (enhanced test runner)" do
    test "discovers and runs tests in test/ directory", %{tmp_dir: tmp, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "math_test.skein"), """
      module MathTest {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "addition works" {
          assert add(1, 2) == 3
        }

        test "negative addition" {
          assert add(0 - 1, 0 - 2) == 0 - 3
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 2
      assert result.passed == 2
      assert result.failed == 0
      assert result.files == 1
    end

    test "also discovers tests in src/ files", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "greeter.skein"), """
      module Greeter {
        fn greet(name: String) -> String {
          "Hi, ${name}!"
        }

        test "greet works" {
          assert greet("Bob") == "Hi, Bob!"
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 1
      assert result.passed == 1
    end

    test "reports failures with file context", %{tmp_dir: tmp, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "fail_test.skein"), """
      module FailTest {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "wrong answer" {
          assert add(2, 2) == 5
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 1
      assert result.failed == 1

      [failure] = result.results |> Enum.filter(&(&1.status == :failed))
      assert failure.file =~ "fail_test.skein"
    end

    test "aggregates results across multiple files", %{tmp_dir: tmp, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "a_test.skein"), """
      module ATest {
        fn ok(x: Int) -> Int { x }
        test "a passes" { assert ok(1) == 1 }
      }
      """)

      File.write!(Path.join(test_dir, "b_test.skein"), """
      module BTest {
        fn ok(x: Int) -> Int { x }
        test "b passes" { assert ok(2) == 2 }
        test "b also passes" { assert ok(3) == 3 }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 3
      assert result.passed == 3
      assert result.files == 2
    end

    test "skips files that fail to compile and reports them", %{tmp_dir: tmp, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "good_test.skein"), """
      module GoodTest {
        fn ok(x: Int) -> Int { x }
        test "works" { assert ok(1) == 1 }
      }
      """)

      File.write!(Path.join(test_dir, "bad_test.skein"), """
      module BadTest {
        fn broken( -> { }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 1
      assert result.passed == 1
      assert result.compile_errors == 1

      # The structured errors are carried so the CLI can print them
      bad_file = Path.join(test_dir, "bad_test.skein")
      assert [%{file: ^bad_file, errors: [error | _]}] = result.compile_failed
      assert error.location.file == bad_file
    end

    test "defaults to the current directory with no arguments" do
      # The CLI app has no src/ or test/ .skein files at the default dir
      assert {:error, message} = CLI.test_all([])
      assert message =~ "No .skein files found"
      assert message =~ Path.expand(".")
    end

    test "returns error when no .skein files found", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.test_all([tmp])
      assert message =~ "No .skein files"
    end
  end

  describe "test_all/1 with scenario and golden tests (Phase 8a)" do
    test "discovers and runs scenario tests", %{tmp_dir: tmp, test_dir: test_dir} do
      File.write!(Path.join(test_dir, "scenario_test.skein"), """
      module ScenarioRunner {
        fn add(a: Int, b: Int) -> Int { a + b }

        scenario "addition scenario" {
          given {
            x: 5
            y: 10
          }

          expect {
            assert add(x, y) == 15
          }
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 1
      assert result.passed == 1
      assert result.failed == 0

      [test_result] = result.results
      assert test_result.kind == :scenario
    end

    test "discovers and runs golden tests", %{tmp_dir: tmp, test_dir: test_dir} do
      trace_path = Path.join(test_dir, "trace.json")
      File.write!(trace_path, "[]")

      File.write!(Path.join(test_dir, "golden_test.skein"), """
      module GoldenRunner {
        golden "empty trace" from trace "#{trace_path}" {
          assert true
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 1
      assert result.passed == 1

      [test_result] = result.results
      assert test_result.kind == :golden
    end

    test "runs mixed test/scenario/golden and aggregates results", %{
      tmp_dir: tmp,
      test_dir: test_dir
    } do
      trace_path = Path.join(test_dir, "mix_trace.json")
      File.write!(trace_path, "[]")

      File.write!(Path.join(test_dir, "mixed_test.skein"), """
      module MixedTests {
        fn ok() -> Bool { true }

        test "unit test" { assert ok() }

        scenario "scenario test" {
          given { n: 42 }
          expect { assert n == 42 }
        }

        golden "golden test" from trace "#{trace_path}" {
          assert ok()
        }
      }
      """)

      assert {:ok, result} = CLI.test_all([tmp])
      assert result.total == 3
      assert result.passed == 3

      kinds = Enum.map(result.results, & &1.kind)
      assert :test in kinds
      assert :scenario in kinds
      assert :golden in kinds
    end
  end
end
