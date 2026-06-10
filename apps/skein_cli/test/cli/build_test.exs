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

    test "registers declared tools from compiled modules", %{tmp_dir: tmp, src_dir: src} do
      Skein.Runtime.Tool.clear_registry()

      File.write!(Path.join(src, "tools.skein"), """
      module BuildToolService {
        tool Build.Double {
          description: "Doubles an integer"
          input { n: Int }
          output { doubled: Int }
          implement { Ok({ doubled: n + n }) }
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      assert result.errors == 0

      caps = [%{kind: "tool.use", params: ["Build.Double"]}]
      assert {:ok, %{doubled: 8}} = Skein.Runtime.Tool.call("Build.Double", %{n: 4}, caps)
    end

    test "registers tools when building to disk with --output", %{
      tmp_dir: tmp,
      src_dir: src,
      build_dir: build
    } do
      Skein.Runtime.Tool.clear_registry()

      File.write!(Path.join(src, "tools.skein"), """
      module BuildDiskToolService {
        tool BuildDisk.Triple {
          description: "Triples an integer"
          input { n: Int }
          output { tripled: Int }
          implement { Ok({ tripled: n + n + n }) }
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp, "--output", build])
      assert result.errors == 0

      caps = [%{kind: "tool.use", params: ["BuildDisk.Triple"]}]
      assert {:ok, %{tripled: 9}} = Skein.Runtime.Tool.call("BuildDisk.Triple", %{n: 3}, caps)
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

    test "defaults to the current directory with no arguments" do
      # The CLI app has no src/ directory, so the default-dir search fails
      assert {:error, message} = CLI.build([])
      assert message =~ "No .skein files found"
      assert message =~ Path.expand(".")
    end

    test "rejects unknown flags instead of treating them as a directory", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.build(["-v", tmp])
      assert message =~ "Unknown option: -v"
    end

    test "rejects a second positional argument", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.build([tmp, "extra"])
      assert message =~ "Unexpected argument: extra"
    end

    test "errors when --output is missing its value", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.build([tmp, "--output"])
      assert message =~ "Missing value for --output"
    end

    test "points at stray root-level .skein files when src/ is empty", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "hello.skein"), """
      module Hello {
        fn hi() -> String { "hi" }
      }
      """)

      assert {:error, message} = CLI.build([tmp])
      assert message =~ "hello.skein"
      assert message =~ "src/"
      assert message =~ "skein compile"
    end

    test "failed builds carry structured errors with the file path", %{
      tmp_dir: tmp,
      src_dir: src
    } do
      bad = Path.join(src, "bad.skein")

      File.write!(bad, """
      module Bad {
        fn hi() -> String {
          "hi";
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      assert result.errors == 1
      assert [%{file: ^bad, errors: [error]}] = result.failed
      assert error.location.file == bad
      assert error.fix_hint =~ "semicolons"
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

  describe "build/1 with --output" do
    test "writes .beam files to output directory", %{
      tmp_dir: tmp,
      src_dir: src,
      build_dir: build_dir
    } do
      File.write!(Path.join(src, "math.skein"), """
      module Math {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """)

      assert {:ok, result} = CLI.build([tmp, "--output", build_dir])
      assert result.compiled == 1
      assert result.output_dir == build_dir

      # Verify .beam file was written
      beam_files = Path.wildcard(Path.join(build_dir, "*.beam"))
      assert length(beam_files) == 1
      assert hd(beam_files) =~ "Elixir.Skein.User.Math.beam"
    end

    test "writes multiple .beam files to output directory", %{
      tmp_dir: tmp,
      src_dir: src,
      build_dir: build_dir
    } do
      File.write!(Path.join(src, "math.skein"), """
      module Math {
        fn add(a: Int, b: Int) -> Int { a + b }
      }
      """)

      File.write!(Path.join(src, "greeter.skein"), """
      module Greeter {
        fn hello(name: String) -> String { "Hello, ${name}!" }
      }
      """)

      assert {:ok, result} = CLI.build([tmp, "--output", build_dir])
      assert result.compiled == 2

      beam_files = Path.wildcard(Path.join(build_dir, "*.beam")) |> Enum.sort()
      assert length(beam_files) == 2
    end

    test "beam files can be loaded and executed", %{
      tmp_dir: tmp,
      src_dir: src,
      build_dir: build_dir
    } do
      File.write!(Path.join(src, "loader_test.skein"), """
      module LoaderTest {
        fn multiply(a: Int, b: Int) -> Int {
          a * b
        }
      }
      """)

      {:ok, _result} = CLI.build([tmp, "--output", build_dir])

      # Purge the in-memory module so we can verify loading from disk
      mod = :"Elixir.Skein.User.LoaderTest"
      :code.purge(mod)
      :code.delete(mod)

      # Load from .beam file
      beam_path = Path.join(build_dir, "Elixir.Skein.User.LoaderTest.beam")
      assert File.exists?(beam_path)
      {:ok, beam_binary} = File.read(beam_path)
      {:module, loaded_mod} = :code.load_binary(mod, ~c"#{beam_path}", beam_binary)

      assert loaded_mod.multiply(6, 7) == 42
    end

    test "creates output directory if it doesn't exist", %{tmp_dir: tmp, src_dir: src} do
      new_output = Path.join(tmp, "new_output_dir")
      refute File.dir?(new_output)

      File.write!(Path.join(src, "simple.skein"), """
      module Simple {
        fn id(x: Int) -> Int { x }
      }
      """)

      assert {:ok, result} = CLI.build([tmp, "--output", new_output])
      assert result.compiled == 1
      assert File.dir?(new_output)

      beam_files = Path.wildcard(Path.join(new_output, "*.beam"))
      assert length(beam_files) == 1
    end

    test "build without --output does not write beam files", %{
      tmp_dir: tmp,
      src_dir: src,
      build_dir: build_dir
    } do
      File.write!(Path.join(src, "no_output.skein"), """
      module NoOutput {
        fn x() -> Int { 1 }
      }
      """)

      assert {:ok, result} = CLI.build([tmp])
      refute Map.has_key?(result, :output_dir)

      # Build dir should be empty
      beam_files = Path.wildcard(Path.join(build_dir, "*.beam"))
      assert beam_files == []
    end
  end
end
