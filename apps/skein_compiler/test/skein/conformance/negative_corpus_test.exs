defmodule Skein.Conformance.NegativeCorpusTest do
  @moduledoc """
  The **negative-fixture corpus** for the GA conformance gate (#262).

  Every `*.skein` file under `conformance/negative/` is a program that MUST be
  rejected by the compiler — these are the soundness holes Wave 1 closed (the
  cases that would have caught #259 and friends). Each fixture declares the
  diagnostic code(s) it must produce in a header line:

      -- expect: E0020
      -- expect: E0020, E0022

  The runner compiles each fixture through the full `check_file` pipeline and
  asserts (a) compilation is NOT clean, (b) the **complete** set of distinct
  diagnostic codes exactly equals the `expect:` header (#262 — an unexpected
  extra diagnostic is drift, not noise), and (c) every emitted error honors the
  structured-diagnostic contract: populated code/severity/message/location and
  JSON-serializability, with `fix_code` either applicable Skein or nil (never a
  `//` placeholder). This pins the soundness contract so a future change can't
  silently make one of these crash-at-runtime programs compile again, nor
  degrade what an agent sees when they fail.

  Adding a fixture file (with an `expect:` header) automatically adds a test —
  no code change required.
  """
  use ExUnit.Case, async: true

  @fixtures_dir Path.join(__DIR__, "negative")

  defp expected_codes(source) do
    Regex.scan(~r/--\s*expect:\s*([A-Z0-9, ]+)/, source)
    |> Enum.flat_map(fn [_, codes] ->
      codes |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
    |> Enum.uniq()
  end

  defp assert_diagnostic_quality!(error, fixture_name) do
    assert is_binary(error.code) and error.code =~ ~r/\A[EW]\d{4}\z/,
           "fixture #{fixture_name}: malformed diagnostic code #{inspect(error.code)}"

    assert error.severity in [:error, :warning]
    assert is_binary(error.message) and error.message != ""
    assert String.length(error.message) <= 240,
           "fixture #{fixture_name}: diagnostic message should be short and focused"

    assert is_binary(error.fix_hint) and error.fix_hint != "",
           "fixture #{fixture_name}: #{error.code} is missing an agent-usable fix_hint"

    assert %{file: _, line: line, col: col} = error.location
    assert is_integer(line) and line >= 1
    assert is_integer(col) and col >= 1

    assert %{start: %{line: start_line, col: start_col}, end: %{line: end_line, col: end_col}} =
             error.span,
           "fixture #{fixture_name}: #{error.code} is missing a precise span"

    assert start_line >= 1 and start_col >= 1 and end_line >= start_line and end_col >= 1

    assert error.edit_kind == nil or error.edit_kind in Skein.Error.edit_kinds(),
           "fixture #{fixture_name}: mechanical fix_code must declare a valid edit_kind"

    refute is_binary(error.fix_code) and error.fix_code =~ ~r|\A\s*(//|#|TODO|FIXME)|i,
           "fixture #{fixture_name}: placeholder/non-Skein fix_code #{inspect(error.fix_code)}"

    assert {:ok, _} = Jason.encode(error),
           "fixture #{fixture_name}: diagnostic not JSON-serializable"
  end

  @fixtures Path.wildcard(Path.join(@fixtures_dir, "*.skein"))

  test "the corpus is non-empty (guards against a glob/path regression)" do
    assert length(@fixtures) >= 8,
           "expected the negative corpus to hold the Wave 1 soundness fixtures"

    fixture_names = Enum.map(@fixtures, &Path.basename/1)

    for required <- [
          "nondeterminism_requires_capability.skein",
          "agent_invalid_phase_transition.skein",
          "tool_call_input_shape_mismatch.skein",
          "tool_implement_output_shape_mismatch.skein",
          "effect_missing_unwrap.skein",
          "builtin_error_variant_unknown.skein",
          "interpolation_uncoercible.skein",
          "accidental_cross_module_call.skein"
        ] do
      assert required in fixture_names,
             "negative corpus is missing high-frequency agent mistake fixture #{required}"
    end
  end

  test "diagnostic quality gate rejects placeholder/non-Skein fix_code" do
    diagnostic = %Skein.Error{
      code: "E9999",
      severity: :error,
      message: "Synthetic diagnostic",
      location: %{file: "bad.skein", line: 1, col: 1},
      span: Skein.Error.point(1, 1),
      fix_hint: "Use real Skein syntax for machine-applicable fixes",
      fix_code: "// TODO: fix this",
      edit_kind: :replace
    }

    assert_raise ExUnit.AssertionError, fn ->
      assert_diagnostic_quality!(diagnostic, "synthetic_placeholder.skein")
    end
  end

  for fixture <- @fixtures do
    name = Path.basename(fixture)

    @tag :conformance
    test "negative fixture rejected: #{name}" do
      source = File.read!(unquote(fixture))
      expected = expected_codes(source)

      assert expected != [],
             "fixture #{unquote(name)} is missing an `-- expect: <CODE>` header"

      {:ok, %{errors: errors}} = Skein.Compiler.check_file(unquote(fixture))
      codes = errors |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort()

      assert errors != [],
             "fixture #{unquote(name)} was expected to FAIL to compile, but it was accepted"

      assert codes == Enum.sort(expected),
             "fixture #{unquote(name)} must emit exactly #{Enum.join(expected, ", ")}, " <>
               "got: #{Enum.join(codes, ", ")} — update the `-- expect:` header if the " <>
               "new diagnostic set is intentional"

      # The structured-diagnostic contract (spec §7): agents consume these.
      for error <- errors do
        assert_diagnostic_quality!(error, unquote(name))
      end
    end
  end
end
