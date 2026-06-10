defmodule Skein.CLI.AgentsTest do
  use ExUnit.Case, async: false

  alias Skein.CLI
  alias Skein.CLI.AgentsMd

  @tmp_dir Path.expand("../../tmp/agents_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir}
  end

  describe "agents/1" do
    test "creates AGENTS.md when absent", %{tmp_dir: tmp} do
      assert {:ok, %{action: :created, path: path}} = CLI.agents([tmp])
      assert path == Path.join(tmp, "AGENTS.md")

      content = File.read!(path)
      assert content =~ AgentsMd.start_marker()
      assert content =~ AgentsMd.end_marker()
      assert content =~ "## Syntax Cheatsheet"
      assert content =~ "https://kormie.github.io/Skein/llms.txt"
    end

    test "regeneration is idempotent", %{tmp_dir: tmp} do
      {:ok, %{path: path}} = CLI.agents([tmp])
      first = File.read!(path)

      assert {:ok, %{action: :updated}} = CLI.agents([tmp])
      assert File.read!(path) == first
    end

    test "preserves user content outside the markers", %{tmp_dir: tmp} do
      path = Path.join(tmp, "AGENTS.md")

      File.write!(path, """
      # My Project

      Custom instructions above the block.

      #{AgentsMd.start_marker()}
      stale generated content from an old toolchain
      #{AgentsMd.end_marker()}

      Custom instructions below the block.
      """)

      assert {:ok, %{action: :updated}} = CLI.agents([tmp])
      content = File.read!(path)

      assert content =~ "Custom instructions above the block."
      assert content =~ "Custom instructions below the block."
      refute content =~ "stale generated content"
      assert content =~ "## Syntax Cheatsheet"
    end

    test "appends the generated block when markers are missing", %{tmp_dir: tmp} do
      path = Path.join(tmp, "AGENTS.md")
      File.write!(path, "# Hand-written agent notes\n")

      assert {:ok, %{action: :updated}} = CLI.agents([tmp])
      content = File.read!(path)

      assert content =~ "# Hand-written agent notes"
      assert content =~ AgentsMd.start_marker()
      assert content =~ "## Syntax Cheatsheet"
    end

    test "defaults to the current directory" do
      # Just verify arg parsing accepts no args; run in tmp via File.cd!
      File.cd!(@tmp_dir, fn ->
        assert {:ok, %{action: :created}} = CLI.agents([])
        assert File.exists?("AGENTS.md")
      end)
    end

    test "errors for a missing directory", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.agents([Path.join(tmp, "nope")])
      assert message =~ "No such directory"
    end

    test "rejects unknown flags" do
      assert {:error, message} = CLI.agents(["--bogus"])
      assert message =~ "Unknown option: --bogus"
    end
  end

  describe "AgentsMd.generated_block/0" do
    test "embeds the toolchain version" do
      vsn = Application.spec(:skein_cli, :vsn) |> to_string()
      assert AgentsMd.generated_block() =~ "(skein #{vsn})"
    end

    test "matches the docs-site primer source (no drift)" do
      primer_path =
        Path.expand(
          "../../../../docs/site/src/content/docs/reference/agent-primer.md",
          __DIR__
        )

      raw = File.read!(primer_path)
      {pos, _} = :binary.match(raw, "\n## ")
      body = raw |> binary_part(pos + 1, byte_size(raw) - pos - 1) |> String.trim()

      assert String.contains?(AgentsMd.generated_block(), body)
    end
  end
end
