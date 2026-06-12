defmodule Skein.CLITest do
  use ExUnit.Case, async: false

  alias Skein.CLI

  test "skein_lsp is available for the lsp subcommand" do
    assert Code.ensure_loaded?(SkeinLsp)
  end

  @fixtures_dir Path.expand("fixtures", __DIR__)

  setup do
    File.mkdir_p!(@fixtures_dir)

    # Write a simple .skein file for testing
    hello_path = Path.join(@fixtures_dir, "hello.skein")

    File.write!(hello_path, """
    module Hello {
      fn greet(name: String) -> String {
        "Hello, ${name}!"
      }

      fn add(a: Int, b: Int) -> Int {
        a + b
      }

      test "greet works" {
        assert greet("World") == "Hello, World!"
      }

      test "add works" {
        assert add(2, 3) == 5
      }
    }
    """)

    on_exit(fn ->
      File.rm_rf!(@fixtures_dir)
    end)

    %{hello_path: hello_path}
  end

  describe "compile/1" do
    test "compiles a valid .skein file", %{hello_path: path} do
      assert {:ok, mod, []} = CLI.compile([path])
      assert mod.greet("Skein") == "Hello, Skein!"
    end

    test "surfaces analyzer warnings alongside the compiled module" do
      path = Path.join(@fixtures_dir, "warned.skein")

      File.write!(path, """
      module Warned {
        capability http.out("api.example.com")

        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """)

      assert {:ok, mod, [warning]} = CLI.compile([path])
      assert mod.greet("Skein") == "Hello, Skein!"
      assert warning.code == "W0002"
    end

    test "returns structured errors for a file that fails to compile" do
      path = Path.join(@fixtures_dir, "broken.skein")

      File.write!(path, """
      module Broken {
        fn greet(name: String) -> String {
      """)

      assert {:error, [%Skein.Error{} | _]} = CLI.compile([path])
    end

    test "returns error for nonexistent file" do
      assert {:error, _} = CLI.compile(["nonexistent.skein"])
    end

    test "returns error with no arguments" do
      assert {:error, message} = CLI.compile([])
      assert message =~ "Usage"
    end
  end

  describe "test/1" do
    test "runs tests in a .skein file and reports results", %{hello_path: path} do
      assert {:ok, results} = CLI.test([path])
      assert results.total == 2
      assert results.passed == 2
      assert results.failed == 0
    end

    test "reports failing tests" do
      fail_path = Path.join(@fixtures_dir, "fail.skein")

      File.write!(fail_path, """
      module FailTest {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "wrong assertion" {
          assert add(2, 3) == 99
        }
      }
      """)

      assert {:ok, results} = CLI.test([fail_path])
      assert results.total == 1
      assert results.passed == 0
      assert results.failed == 1
    end

    test "failing assertions report operands, expression, and location" do
      fail_path = Path.join(@fixtures_dir, "fail_rich.skein")

      File.write!(fail_path, """
      module FailRichTest {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "wrong assertion" {
          assert add(2, 3) == 99
        }
      }
      """)

      assert {:ok, results} = CLI.test([fail_path])
      [failure] = Enum.filter(results.results, &(&1.status == :failed))

      assert failure.error =~ "add(2, 3) == 99"
      assert failure.error =~ "left:  5"
      assert failure.error =~ "right: 99"
      assert failure.location =~ "fail_rich.skein:5"
    end

    test "returns error with no arguments" do
      assert {:error, message} = CLI.test([])
      assert message =~ "Usage"
    end
  end
end
