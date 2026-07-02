defmodule Skein.CLI.DogfoodPinsFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the pinned dogfood revisions.

  The dogfood gate is only executable when the pins are exact: every
  project must pin a full commit SHA (not a branch or tag, which move)
  and an exact expected test count, and the checked-in corpus must have a
  directory per pin. The corpus itself is executed by
  `dogfood_corpus_test.exs`; CI's dogfood job clones each upstream repo
  at its pin.
  """

  @pins_file Path.expand("../../../../conformance/dogfood.json", __DIR__)
  @corpus_dir Path.expand("../../../../conformance/dogfood", __DIR__)

  test "every dogfood project pins an exact revision and test count" do
    assert File.exists?(@pins_file), "conformance/dogfood.json is missing"

    %{"projects" => projects} = @pins_file |> File.read!() |> Jason.decode!()
    assert map_size(projects) > 0, "no dogfood projects pinned"

    for {name, pin} <- projects do
      assert pin["repo"] =~ ~r{\A[\w.-]+/[\w.-]+\z},
             "#{name}: repo must be owner/name, got #{inspect(pin["repo"])}"

      assert pin["rev"] =~ ~r/\A[0-9a-f]{40}\z/,
             "#{name}: rev must be a full 40-hex commit SHA, got #{inspect(pin["rev"])}"

      assert is_integer(pin["expected_tests"]) and pin["expected_tests"] > 0,
             "#{name}: expected_tests must be a positive integer"

      assert File.dir?(Path.join(@corpus_dir, name)),
             "#{name}: pinned project has no checked-in corpus under conformance/dogfood/"
    end
  end
end
