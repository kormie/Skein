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
  asserts (a) compilation is NOT clean and (b) every expected code is present.
  This pins the soundness contract so a future change can't silently make one of
  these crash-at-runtime programs compile again.

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
      codes = Enum.map(errors, & &1.code)

      assert errors != [],
             "fixture #{unquote(name)} was expected to FAIL to compile, but it was accepted"

      for code <- expected do
        assert code in codes,
               "fixture #{unquote(name)} expected diagnostic #{code}, got: #{Enum.join(codes, ", ")}"
      end
    end
  end
end
