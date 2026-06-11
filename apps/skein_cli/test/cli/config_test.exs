defmodule Skein.CLI.ConfigTest do
  @moduledoc """
  Tests for skein.toml parsing and LLM environment profile resolution
  (issue #107): the capability declaration never changes — only the
  backend serving the call does, selected by SKEIN_ENV / --env.
  """
  use ExUnit.Case, async: false

  alias Skein.CLI.Config
  alias Skein.Runtime.Llm

  setup do
    previous = Llm.get_backend()
    on_exit(fn -> Llm.set_backend(previous) end)

    tmp = Path.join(System.tmp_dir!(), "skein_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    [tmp_dir: tmp]
  end

  defp write_toml(dir, contents) do
    File.write!(Path.join(dir, "skein.toml"), contents)
    dir
  end

  describe "parse/1" do
    test "parses tables, strings, comments, and nested tables" do
      assert {:ok, parsed} =
               Config.parse("""
               # project file
               [project]
               name = "demo"

               [env.dev.llm]
               backend = "openai_compatible"
               base_url = "http://localhost:10240/v1"
               """)

      assert parsed["project"]["name"] == "demo"
      assert parsed["env"]["dev"]["llm"]["backend"] == "openai_compatible"
      assert parsed["env"]["dev"]["llm"]["base_url"] == "http://localhost:10240/v1"
    end

    test "parses inline tables for model_map" do
      assert {:ok, parsed} =
               Config.parse("""
               [env.dev.llm]
               model_map = { "claude-opus-4-8" = "mlx-community/Qwen3-30B", "claude-haiku-4-5" = "qwen-small" }
               """)

      assert parsed["env"]["dev"]["llm"]["model_map"] == %{
               "claude-opus-4-8" => "mlx-community/Qwen3-30B",
               "claude-haiku-4-5" => "qwen-small"
             }
    end

    test "reports unparseable lines with their line number" do
      assert {:error, message} =
               Config.parse("""
               [llm]
               backend ===== what
               """)

      assert message =~ "line 2"
    end
  end

  describe "llm_profile/2" do
    test "no [llm] section and no env profile resolves to nil" do
      {:ok, parsed} = Config.parse("[project]\nname = \"x\"\n")
      assert Config.llm_profile(parsed, nil) == nil
      assert Config.llm_profile(parsed, "dev") == nil
    end

    test "the default [llm] section applies when no environment is selected" do
      {:ok, parsed} = Config.parse("[llm]\nbackend = \"anthropic\"\n")
      assert %{"backend" => "anthropic"} = Config.llm_profile(parsed, nil)
    end

    test "an env profile overrides the default for that environment" do
      {:ok, parsed} =
        Config.parse("""
        [llm]
        backend = "anthropic"

        [env.dev.llm]
        backend = "openai_compatible"
        base_url = "http://localhost:10240/v1"
        """)

      assert %{"backend" => "anthropic"} = Config.llm_profile(parsed, nil)
      assert %{"backend" => "openai_compatible"} = Config.llm_profile(parsed, "dev")
      # An env without its own profile falls back to the default
      assert %{"backend" => "anthropic"} = Config.llm_profile(parsed, "staging")
    end
  end

  describe "apply_llm_profile/2" do
    test "no skein.toml leaves the backend untouched", %{tmp_dir: tmp} do
      Llm.set_backend(Llm.TestBackend)
      assert :noop = Config.apply_llm_profile(tmp, nil)
      assert Llm.get_backend() == Llm.TestBackend
    end

    test "anthropic backend selects AnthropicBackend", %{tmp_dir: tmp} do
      write_toml(tmp, "[llm]\nbackend = \"anthropic\"\n")

      assert {:ok, _desc} = Config.apply_llm_profile(tmp, nil)
      assert Llm.get_backend() == Skein.Runtime.Llm.AnthropicBackend
    end

    test "test backend selects TestBackend", %{tmp_dir: tmp} do
      write_toml(tmp, "[env.ci.llm]\nbackend = \"test\"\n")

      assert {:ok, _desc} = Config.apply_llm_profile(tmp, "ci")
      assert Llm.get_backend() == Skein.Runtime.Llm.TestBackend
    end

    test "openai_compatible selects the tuple backend with base_url and model_map", %{
      tmp_dir: tmp
    } do
      write_toml(tmp, """
      [env.dev.llm]
      backend = "openai_compatible"
      base_url = "http://localhost:10240/v1"
      model_map = { "claude-opus-4-8" = "mlx-community/Qwen3-30B" }
      """)

      assert {:ok, desc} = Config.apply_llm_profile(tmp, "dev")
      assert desc =~ "http://localhost:10240/v1"

      assert {Skein.Runtime.Llm.OpenAiCompatibleBackend, config} = Llm.get_backend()
      assert config.base_url == "http://localhost:10240/v1"
      assert config.model_map == %{"claude-opus-4-8" => "mlx-community/Qwen3-30B"}
      assert config.api_key == nil
    end

    test "api_key_env resolves the key from the environment", %{tmp_dir: tmp} do
      System.put_env("SKEIN_CONFIG_TEST_KEY", "local-secret")
      on_exit(fn -> System.delete_env("SKEIN_CONFIG_TEST_KEY") end)

      write_toml(tmp, """
      [env.dev.llm]
      backend = "openai_compatible"
      base_url = "http://localhost:10240/v1"
      api_key_env = "SKEIN_CONFIG_TEST_KEY"
      """)

      assert {:ok, _} = Config.apply_llm_profile(tmp, "dev")
      assert {_module, config} = Llm.get_backend()
      assert config.api_key == "local-secret"
    end

    test "openai_compatible without base_url is a structured error", %{tmp_dir: tmp} do
      write_toml(tmp, "[env.dev.llm]\nbackend = \"openai_compatible\"\n")

      assert {:error, message} = Config.apply_llm_profile(tmp, "dev")
      assert message =~ "base_url"
    end

    test "an unknown backend name is a structured error", %{tmp_dir: tmp} do
      write_toml(tmp, "[llm]\nbackend = \"mystery\"\n")

      assert {:error, message} = Config.apply_llm_profile(tmp, nil)
      assert message =~ "mystery"
      assert message =~ "bedrock"
    end

    test "bedrock selects the tuple backend with region and model_map", %{tmp_dir: tmp} do
      write_toml(tmp, """
      [llm]
      backend = "bedrock"
      region = "us-west-2"
      model_map = { "claude-sonnet-4-6" = "global.anthropic.claude-sonnet-4-6" }
      """)

      assert {:ok, desc} = Config.apply_llm_profile(tmp, nil)
      assert desc =~ "bedrock"
      assert desc =~ "us-west-2"

      assert {Skein.Runtime.Llm.BedrockBackend, config} = Llm.get_backend()
      assert config.region == "us-west-2"
      assert config.model_map == %{"claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6"}
    end

    test "bedrock region falls back to AWS_REGION in the environment", %{tmp_dir: tmp} do
      previous = System.get_env("AWS_REGION")

      on_exit(fn ->
        if previous,
          do: System.put_env("AWS_REGION", previous),
          else: System.delete_env("AWS_REGION")
      end)

      System.put_env("AWS_REGION", "eu-central-1")
      write_toml(tmp, "[llm]\nbackend = \"bedrock\"\n")

      assert {:ok, desc} = Config.apply_llm_profile(tmp, nil)
      assert desc =~ "eu-central-1"

      assert {Skein.Runtime.Llm.BedrockBackend, config} = Llm.get_backend()
      assert config.region == "eu-central-1"
    end

    test "bedrock without a region anywhere is a structured error", %{tmp_dir: tmp} do
      previous = System.get_env("AWS_REGION")

      on_exit(fn ->
        if previous,
          do: System.put_env("AWS_REGION", previous),
          else: System.delete_env("AWS_REGION")
      end)

      System.delete_env("AWS_REGION")
      write_toml(tmp, "[llm]\nbackend = \"bedrock\"\n")

      assert {:error, message} = Config.apply_llm_profile(tmp, nil)
      assert message =~ "region"
    end

    test "bedrock base_url override (VPC endpoint) is passed through", %{tmp_dir: tmp} do
      write_toml(tmp, """
      [llm]
      backend = "bedrock"
      region = "us-west-2"
      base_url = "https://vpce-123.bedrock-runtime.us-west-2.vpce.amazonaws.com"
      """)

      assert {:ok, _desc} = Config.apply_llm_profile(tmp, nil)

      assert {Skein.Runtime.Llm.BedrockBackend, config} = Llm.get_backend()
      assert config.base_url == "https://vpce-123.bedrock-runtime.us-west-2.vpce.amazonaws.com"
    end
  end

  describe "CLI wiring" do
    test "skein test --env applies the project's env profile", %{tmp_dir: tmp} do
      {:ok, _} = Skein.CLI.new([Path.join(tmp, "wired_app"), "--no-git", "--no-agents"])
      project_dir = Path.join(tmp, "wired_app")

      File.write!(Path.join(project_dir, "skein.toml"), """
      [project]
      name = "wired_app"

      [build]
      src = "src"
      test = "test"

      [env.ci.llm]
      backend = "test"
      """)

      # Make the applied backend observable: start from a different one
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      assert {:ok, results} = Skein.CLI.test_all([project_dir, "--env", "ci"])
      assert results.failed == 0

      assert Llm.get_backend() == Skein.Runtime.Llm.TestBackend
    end
  end
end
