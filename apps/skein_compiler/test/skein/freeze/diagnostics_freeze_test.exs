defmodule Skein.Freeze.DiagnosticsFreezeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Wave F freeze gate (#332) for the diagnostics registry.

  Post-1.0 codes are append-only: never renumbered, repurposed, or
  deleted, and a severity change is breaking. This suite pins the spec §7
  table (code → category/severity) against
  `conformance/freeze/diagnostics.json`, the structured-error field set,
  the `edit_kind` inventory, and the three-place registry discipline
  (spec §7 ↔ docs-site errors page).

  Meaning *text* may be reworded in minors — the vector deliberately pins
  only code, category, and severity.
  """

  @vector Path.expand("../../../../../conformance/freeze/diagnostics.json", __DIR__)
  @spec_path Path.expand("../../../../../docs/SKEIN_SPEC.md", __DIR__)
  @errors_page Path.expand(
                 "../../../../../docs/site/src/content/docs/compiler/errors.md",
                 __DIR__
               )

  defp vector, do: @vector |> File.read!() |> Jason.decode!()

  defp spec_rows do
    Regex.scan(~r/^\| (E\d{4}|W\d{4}) \| ([^|]+) \| ([^|]+) \|/m, File.read!(@spec_path))
    |> Map.new(fn [_, code, category, severity] ->
      {code, %{"category" => String.trim(category), "severity" => String.trim(severity)}}
    end)
  end

  test "spec §7 codes/categories/severities match the frozen vector exactly" do
    assert spec_rows() == vector()["codes"],
           "the spec §7 diagnostics table drifted from conformance/freeze/diagnostics.json — " <>
             "codes are append-only and severity changes are breaking; a deliberate " <>
             "addition updates the vector in the same PR"
  end

  test "the code space is the frozen one, append-only from E0044/W0005" do
    codes = Map.keys(vector()["codes"])

    errors = codes |> Enum.filter(&String.starts_with?(&1, "E")) |> Enum.sort()
    warnings = codes |> Enum.filter(&String.starts_with?(&1, "W")) |> Enum.sort()

    expected_errors =
      Enum.map([1, 2, 3] ++ Enum.to_list(10..17) ++ Enum.to_list(20..43), fn n ->
        "E" <> String.pad_leading(Integer.to_string(n), 4, "0")
      end)

    assert errors == expected_errors
    assert warnings == ["W0001", "W0002", "W0003", "W0004"]
  end

  test "the structured-error field set is frozen (gains only)" do
    fields =
      %Skein.Error{}
      |> Map.from_struct()
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    assert fields == vector()["error_fields"],
           "Skein.Error's fields drifted from the frozen vector — the structured " <>
             "shape only gains fields (docs/STABILITY.md); removals/renames are breaking"
  end

  test "the edit_kind inventory is frozen (append-only)" do
    kinds = Skein.Error.edit_kinds() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    assert kinds == vector()["edit_kinds"]
  end

  test "every frozen code is documented on the docs-site errors page" do
    errors_page = File.read!(@errors_page)

    missing =
      vector()["codes"]
      |> Map.keys()
      |> Enum.reject(&String.contains?(errors_page, &1))

    assert missing == [],
           "codes missing from the docs-site errors page (three-place registry " <>
             "discipline): #{inspect(missing)}"
  end
end
