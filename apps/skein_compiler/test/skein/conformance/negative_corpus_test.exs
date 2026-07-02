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

  @fixtures Path.wildcard(Path.join(@fixtures_dir, "*.skein"))

  test "the corpus is non-empty (guards against a glob/path regression)" do
    assert length(@fixtures) >= 8,
           "expected the negative corpus to hold the Wave 1 soundness fixtures"
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
        assert is_binary(error.code) and error.code =~ ~r/\A[EW]\d{4}\z/,
               "fixture #{unquote(name)}: malformed diagnostic code #{inspect(error.code)}"

        assert error.severity in [:error, :warning]
        assert is_binary(error.message) and error.message != ""

        assert %{file: _, line: line, col: col} = error.location
        assert is_integer(line) and line >= 1
        assert is_integer(col) and col >= 1

        # fix_code is applicable Skein or nil — never a `//` placeholder (#313).
        refute is_binary(error.fix_code) and error.fix_code =~ ~r|\A\s*//|,
               "fixture #{unquote(name)}: placeholder fix_code #{inspect(error.fix_code)}"

        assert {:ok, _} = Jason.encode(error),
               "fixture #{unquote(name)}: diagnostic not JSON-serializable"
      end
    end
  end
end
