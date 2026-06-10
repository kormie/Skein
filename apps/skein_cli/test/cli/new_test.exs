defmodule Skein.CLI.NewTest do
  use ExUnit.Case, async: false

  alias Skein.CLI

  @tmp_dir Path.expand("../../tmp/new_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir}
  end

  describe "new/1" do
    test "creates project directory with correct structure", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "my_service")

      assert {:ok, ^project_dir} = CLI.new([project_dir])

      # Top-level files
      assert File.exists?(Path.join(project_dir, "skein.toml"))
      assert File.exists?(Path.join(project_dir, "README.md"))

      # Source directory with example file
      assert File.exists?(Path.join(project_dir, "src/main.skein"))

      # Test directory with example test
      assert File.exists?(Path.join(project_dir, "test/main_test.skein"))
    end

    test "generates valid skein.toml with project name", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "cool_app")
      {:ok, _} = CLI.new([project_dir])

      toml = File.read!(Path.join(project_dir, "skein.toml"))
      assert toml =~ ~s(name = "cool_app")
      assert toml =~ ~s(version = "0.1.0")
    end

    test "generates a compilable main.skein", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "hello_app")
      {:ok, _} = CLI.new([project_dir])

      source = File.read!(Path.join(project_dir, "src/main.skein"))
      assert {:ok, _tokens} = Skein.Lexer.tokenize(source)
    end

    test "hyphenated project names produce a valid module name that builds", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "skein-tests")
      {:ok, _} = CLI.new([project_dir])

      source = File.read!(Path.join(project_dir, "src/main.skein"))
      assert source =~ "module SkeinTests {"

      assert {:ok, result} = CLI.build([project_dir])
      assert result.errors == 0

      assert {:ok, tests} = CLI.test_all([project_dir])
      assert tests.compile_errors == 0
      assert tests.passed == 1
    end

    test "names not starting with a letter get a Skein prefix", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "9lives")
      {:ok, _} = CLI.new([project_dir])

      source = File.read!(Path.join(project_dir, "src/main.skein"))
      assert source =~ "module Skein9lives {"

      assert {:ok, result} = CLI.build([project_dir])
      assert result.errors == 0
    end

    test "generates a compilable test file", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "test_app")
      {:ok, _} = CLI.new([project_dir])

      source = File.read!(Path.join(project_dir, "test/main_test.skein"))
      assert {:ok, _tokens} = Skein.Lexer.tokenize(source)
    end

    test "derives project name from directory basename", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "my_awesome_service")
      {:ok, _} = CLI.new([project_dir])

      toml = File.read!(Path.join(project_dir, "skein.toml"))
      assert toml =~ ~s(name = "my_awesome_service")
    end

    test "returns error when no arguments given" do
      assert {:error, message} = CLI.new([])
      assert message =~ "Usage"
    end

    test "returns error when directory already exists", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "existing")
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "skein.toml"), "existing")

      assert {:error, message} = CLI.new([project_dir])
      assert message =~ "already exists"
    end

    test "README includes project name", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "documented_app")
      {:ok, _} = CLI.new([project_dir])

      readme = File.read!(Path.join(project_dir, "README.md"))
      assert readme =~ "documented_app"
    end
  end
end
