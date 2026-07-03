defmodule Skein.CLI.SurfaceFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the CLI surface: commands and flags,
  `--json` output schema versions, and the recognized `skein.toml` keys.

  The command/flag inventory has no programmatic registry, so the freeze
  pins the two canonical hand-maintained surfaces verbatim — the help
  text (`Skein.CLI.Main.usage_text/0`) and the zsh completions script —
  as text vectors under `conformance/freeze/`. A command or flag rename/
  removal changes those vectors; per `docs/STABILITY.md` that is a major.
  New commands/flags are minors: regenerate deliberately with
  FREEZE_REGEN=1 and review the diff.
  """

  alias Skein.CLI.Json

  @usage_vector Path.expand("../../../../conformance/freeze/cli_usage.txt", __DIR__)
  @completions_vector Path.expand(
                        "../../../../conformance/freeze/cli_completions.zsh",
                        __DIR__
                      )
  @surface_vector Path.expand("../../../../conformance/freeze/cli_surface.json", __DIR__)

  defp pin_text(vector_path, current, label) do
    if System.get_env("FREEZE_REGEN") == "1" do
      File.write!(vector_path, current)
      flunk("regenerated #{vector_path} — review the diff and commit it deliberately")
    else
      assert current == File.read!(vector_path),
             "#{label} drifted from #{Path.basename(vector_path)} — removals/renames " <>
               "are breaking (docs/STABILITY.md); deliberate additions regenerate " <>
               "the vector (FREEZE_REGEN=1) in the same PR"
    end
  end

  test "the help text (command/flag inventory) is frozen" do
    # The banner's version number is release-churn, not frozen surface —
    # normalize it so the pin survives version bumps.
    normalized =
      Regex.replace(
        ~r/\ASkein \S+ —/,
        Skein.CLI.Main.usage_text(),
        "Skein <version> —"
      )

    pin_text(@usage_vector, normalized, "skein usage text")
  end

  test "the zsh completions (per-command flag surface) are frozen" do
    {:ok, script} = Skein.CLI.completions(["zsh"])
    pin_text(@completions_vector, script, "zsh completions script")
  end

  defp surface_vector, do: @surface_vector |> File.read!() |> Jason.decode!()

  test "--json envelope schema versions are frozen" do
    built = [
      Json.trace({:error, "x"}),
      Json.test({:error, "x"}),
      Json.compile({:error, "x"}),
      Json.build({:error, "x"})
    ]

    schemas = built |> Enum.map(& &1.schema) |> Enum.sort()
    assert schemas == surface_vector()["json_schemas"]

    # The envelope itself: schema + ok + data, exactly (additive changes
    # would version the schema string instead).
    for envelope <- built do
      assert envelope |> Map.keys() |> Enum.sort() == [:data, :ok, :schema]
    end
  end

  test "every frozen [llm] profile key is still recognized" do
    toml = """
    [llm]
    backend = "openai_compatible"
    base_url = "https://llm.example.com/v1"
    api_key_env = "EXAMPLE_KEY"
    model_map = { "canonical" = "target" }
    region = "us-east-1"
    """

    {:ok, parsed} = Skein.CLI.Config.parse(toml)
    profile = Skein.CLI.Config.llm_profile(parsed, nil)

    assert profile |> Map.keys() |> Enum.sort() == surface_vector()["llm_profile_keys"]
  end

  test "unknown skein.toml keys are never errors (frozen promise)" do
    toml = """
    [project]
    name = "demo"
    some_future_key = "value"

    [totally_unknown_table]
    other = 42
    """

    assert {:ok, _parsed} = Skein.CLI.Config.parse(toml)
  end

  test "the scaffold backend inventory is frozen" do
    {:ok, script} = Skein.CLI.completions(["zsh"])

    for backend <- surface_vector()["new_backends"] do
      assert script =~ backend,
             "--backend value #{backend} missing from the completions script"
    end
  end
end
