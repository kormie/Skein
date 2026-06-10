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
      assert tests.passed == 2
      assert tests.failed == 0
    end

    test "scaffold tests exercise src/ code: co-located test plus tool integration test", %{
      tmp_dir: tmp
    } do
      project_dir = Path.join(tmp, "fresh_app")
      {:ok, _} = CLI.new([project_dir])

      # src holds the function, its co-located test, and the tool that
      # exposes it across modules
      src = File.read!(Path.join(project_dir, "src/main.skein"))
      assert src =~ "fn hello"
      assert src =~ ~s(test "hello returns greeting")
      assert src =~ "tool FreshApp.Greet"

      # test/ exercises src/ through the tool — no duplicated function body
      test_src = File.read!(Path.join(project_dir, "test/main_test.skein"))
      refute test_src =~ "fn hello"
      assert test_src =~ "tool.use(FreshApp.Greet)"
      assert test_src =~ "tool.call(FreshApp.Greet"

      assert {:ok, result} = CLI.test_all([project_dir])
      assert result.compile_errors == 0
      assert result.total == 2
      assert result.passed == 2
    end

    test "breaking src/main.skein turns the scaffold tests red", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "breakable_app")
      {:ok, _} = CLI.new([project_dir])

      main_path = Path.join(project_dir, "src/main.skein")
      broken = String.replace(File.read!(main_path), "Hello, ${name}!", "Goodbye, ${name}!")
      File.write!(main_path, broken)

      assert {:ok, result} = CLI.test_all([project_dir])
      assert result.failed == 2
      assert result.passed == 0
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

    test "scaffold sources analyze without warnings (issue #104)", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "warn_free")
      {:ok, _} = CLI.new([project_dir])

      for relative <- ["src/main.skein", "test/main_test.skein"] do
        source = File.read!(Path.join(project_dir, relative))
        {:ok, tokens} = Skein.Lexer.tokenize(source)
        {:ok, ast} = Skein.Parser.parse(tokens, relative)

        case Skein.Analyzer.analyze(ast, source_text: source) do
          {:ok, _ast} ->
            :ok

          {:ok, _ast, warnings} ->
            flunk("#{relative} analyzed with warnings: #{inspect(warnings)}")

          {:error, errors} ->
            flunk("#{relative} failed analysis: #{inspect(errors)}")
        end
      end
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

    test "scaffolds AGENTS.md with primer content and llms.txt links", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "agent_app")
      {:ok, _} = CLI.new([project_dir])

      agents_md = File.read!(Path.join(project_dir, "AGENTS.md"))

      # Generated block markers
      assert agents_md =~ "<!-- skein:generated:start -->"
      assert agents_md =~ "<!-- skein:generated:end -->"

      # Primer essentials: syntax, capabilities, gotchas, CLI commands
      assert agents_md =~ "## Syntax Cheatsheet"
      assert agents_md =~ "## Capabilities and Effects"
      assert agents_md =~ "## Known Gotchas"
      assert agents_md =~ "`input` is a keyword"
      assert agents_md =~ "skein build"
      assert agents_md =~ "skein test"
      assert agents_md =~ "skein run"

      # Links to published agent docs
      assert agents_md =~ "https://kormie.github.io/Skein/llms.txt"
      assert agents_md =~ "https://kormie.github.io/Skein/llms-full.txt"

      # MCP server registration mention
      assert agents_md =~ "skein mcp"
    end

    test "scaffolds a CLAUDE.md pointer to AGENTS.md", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "claude_app")
      {:ok, _} = CLI.new([project_dir])

      assert File.read!(Path.join(project_dir, "CLAUDE.md")) =~ "See AGENTS.md"
    end

    test "--no-agents skips AGENTS.md and CLAUDE.md", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "no_agents_app")
      {:ok, _} = CLI.new([project_dir, "--no-agents"])

      assert File.exists?(Path.join(project_dir, "skein.toml"))
      refute File.exists?(Path.join(project_dir, "AGENTS.md"))
      refute File.exists?(Path.join(project_dir, "CLAUDE.md"))
    end

    test "git init creates a repo with a .gitignore (outside any work tree)" do
      # The repo tmp dir lives inside the Skein work tree, where init is
      # intentionally skipped — use the system tmp dir instead.
      outside =
        Path.join(System.tmp_dir!(), "skein_new_git_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(outside) end)

      {:ok, _} = CLI.new([outside])

      assert File.dir?(Path.join(outside, ".git"))
      gitignore = File.read!(Path.join(outside, ".gitignore"))
      assert gitignore =~ "_build/"
      assert gitignore =~ "*.beam"
      assert gitignore =~ "erl_crash.dump"
      assert gitignore =~ "*.db"
    end

    test "inside an existing work tree: no nested repo, .gitignore still written", %{
      tmp_dir: tmp
    } do
      project_dir = Path.join(tmp, "nested_app")
      {:ok, _} = CLI.new([project_dir])

      refute File.dir?(Path.join(project_dir, ".git"))
      assert File.exists?(Path.join(project_dir, ".gitignore"))
    end

    test "--no-git skips init but still writes .gitignore" do
      outside =
        Path.join(System.tmp_dir!(), "skein_new_nogit_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(outside) end)

      {:ok, _} = CLI.new([outside, "--no-git"])

      refute File.dir?(Path.join(outside, ".git"))
      assert File.exists?(Path.join(outside, ".gitignore"))
    end

    test "a missing git binary does not fail scaffolding" do
      Application.put_env(:skein_cli, :git_executable, :missing)
      on_exit(fn -> Application.delete_env(:skein_cli, :git_executable) end)

      outside =
        Path.join(
          System.tmp_dir!(),
          "skein_new_missing_git_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(outside) end)

      {:ok, _} = CLI.new([outside])

      refute File.dir?(Path.join(outside, ".git"))
      assert File.exists?(Path.join(outside, ".gitignore"))
      assert File.exists?(Path.join(outside, "skein.toml"))
    end

    test "unknown flags are rejected", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "flagged_app")

      assert {:error, message} = CLI.new([project_dir, "--bogus"])
      assert message =~ "Unknown option: --bogus"
      refute File.exists?(project_dir)
    end

    test "README includes project name", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "documented_app")
      {:ok, _} = CLI.new([project_dir])

      readme = File.read!(Path.join(project_dir, "README.md"))
      assert readme =~ "documented_app"
    end

    test "README describes the co-located test model and the tool seam", %{tmp_dir: tmp} do
      project_dir = Path.join(tmp, "doc_model_app")
      {:ok, _} = CLI.new([project_dir])

      readme = File.read!(Path.join(project_dir, "README.md"))
      assert readme =~ "test"
      assert readme =~ "tool"
      assert readme =~ "cross-module"
    end
  end
end
