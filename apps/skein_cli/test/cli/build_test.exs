defmodule Skein.CLI.BuildTest do
  use ExUnit.Case, async: false

  alias Skein.CLI

  @tmp_dir Path.expand("../../tmp/build_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    # Create a minimal project structure
    src_dir = Path.join(@tmp_dir, "src")
    File.mkdir_p!(src_dir)

    build_dir = Path.join(@tmp_dir, "_build")
    File.mkdir_p!(build_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir, src_dir: src_dir, build_dir: build_dir}
  end

  describe "build/1" do
    test "compiles all .skein files in src/ directory", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "math.skein"), """
      module Math {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """)

      File.write!(Path.join(src, "greeter.skein"), """
      module Greeter {
        fn hello(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      assert result.compiled == 2
      assert result.errors == 0
      assert length(result.modules) == 2
    end

    test "reports compilation errors without stopping", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "good.skein"), """
      module Good {
        fn ok(x: Int) -> Int { x }
      }
      """)

      File.write!(Path.join(src, "bad.skein"), """
      module Bad {
        fn broken( -> {
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      assert result.compiled == 1
      assert result.errors == 1
      assert length(result.failed) == 1
      assert hd(result.failed).file =~ "bad.skein"
    end

    test "returns error when directory has no .skein files", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.build([tmp])
      assert message =~ "No .skein files"
    end

    test "returns error with no arguments" do
      assert {:error, message} = CLI.build([])
      assert message =~ "Usage"
    end

    test "compiled modules are callable", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "calc.skein"), """
      module Calc {
        fn double(n: Int) -> Int {
          n * 2
        }
      }
      """)

      {:ok, result} = CLI.build([tmp])
      [mod] = result.modules
      assert mod.double(21) == 42
    end

    test "discovers .skein files in nested directories", %{tmp_dir: tmp, src_dir: src} do
      nested = Path.join(src, "services")
      File.mkdir_p!(nested)

      File.write!(Path.join(nested, "api.skein"), """
      module Api {
        fn version(x: Int) -> Int { x }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      assert result.compiled == 1
    end
  end
end
