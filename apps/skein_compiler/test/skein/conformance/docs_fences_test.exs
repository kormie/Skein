defmodule Skein.Conformance.DocsFencesTest do
  @moduledoc """
  Compiles every fenced ```skein code block in the language spec and the
  published docs site (#262 / #202 subset) — published examples that don't
  compile are exactly the blocker class every release-readiness sweep keeps
  finding by hand.

  Block classification:

  - **Complete module** (first non-comment line is `module Name {`): must
    compile with **zero errors and zero warnings**.
  - **Error demo** (a complete module annotated with a diagnostic code in a
    comment, e.g. `-- ERROR: E0012` or `[E0012]`): must emit every annotated
    code — so error demos stay accurate too.
  - **Fragment** (not a complete module, or truncated with a `...`
    placeholder): skipped; illustrative by design.

  Spec §8's examples are additionally pinned verbatim by
  `spec_examples_test.exs`. Each (file, block) pair gets its own test, so a
  regression names the exact page and block index.
  """
  use ExUnit.Case, async: true

  @docs_root Path.expand("../../../../../docs", __DIR__)

  @sources Path.wildcard(Path.join(@docs_root, "site/src/content/docs/**/*.{md,mdx}")) ++
             [Path.join(@docs_root, "SKEIN_SPEC.md")]

  @fenced_blocks fn content ->
    Regex.scan(~r/```skein\n(.*?)```/s, content)
    |> Enum.map(fn [_, code] -> code end)
  end

  @complete_module? fn code ->
    first =
      code
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
      |> List.first()

    is_binary(first) and first =~ ~r/\Amodule [A-Z]\w* \{/ and
      not String.contains?(code, "...")
  end

  # Diagnostic codes an error demo annotates in comments; [] = clean example.
  @annotated_codes fn code ->
    ~r/--[^\n]*?\b(E\d{4})\b|\[(E\d{4})\]/
    |> Regex.scan(code)
    |> Enum.map(fn match -> match |> Enum.reject(&(&1 == "")) |> List.last() end)
    |> Enum.uniq()
  end

  @module_blocks (for file <- @sources,
                      {code, index} <- Enum.with_index(@fenced_blocks.(File.read!(file))),
                      @complete_module?.(code) do
                    {Path.relative_to(file, @docs_root), index, code}
                  end)

  test "the docs corpus is non-empty (guards against a glob/path regression)" do
    assert length(@module_blocks) >= 15,
           "expected the docs site to hold complete-module skein fences; " <>
             "found #{length(@module_blocks)} — did the docs tree move?"
  end

  for {page, index, code} <- @module_blocks do
    case @annotated_codes.(code) do
      [] ->
        @tag :conformance
        test "docs fence compiles cleanly: #{page} block ##{index}" do
          assert {:ok, %{errors: errors, warnings: warnings}} =
                   Skein.Compiler.check_string(unquote(code), unquote(page))

          assert errors == [],
                 "published example #{unquote(page)} block ##{unquote(index)} does not " <>
                   "compile:\n" <>
                   Enum.map_join(
                     errors,
                     "\n",
                     &"  #{&1.code} line #{&1.location.line}: #{&1.message}"
                   )

          assert warnings == [],
                 "published example #{unquote(page)} block ##{unquote(index)} has " <>
                   "warnings:\n" <>
                   Enum.map_join(
                     warnings,
                     "\n",
                     &"  #{&1.code} line #{&1.location.line}: #{&1.message}"
                   )
        end

      annotated ->
        @tag :conformance
        test "docs error demo emits its annotated codes: #{page} block ##{index}" do
          assert {:ok, %{errors: errors}} =
                   Skein.Compiler.check_string(unquote(code), unquote(page))

          emitted = errors |> Enum.map(& &1.code) |> Enum.uniq()

          for code <- unquote(annotated) do
            assert code in emitted,
                   "error demo #{unquote(page)} block ##{unquote(index)} annotates " <>
                     "#{code} but the compiler emitted: #{Enum.join(emitted, ", ")} — " <>
                     "the published demo no longer matches the compiler"
          end
        end
    end
  end
end
