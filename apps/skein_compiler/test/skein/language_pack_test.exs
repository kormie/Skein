defmodule Skein.LanguagePackTest do
  @moduledoc """
  Drift gates for the generated AI language pack.

  The pack is intentionally a single loadable context artifact. Keep it small
  enough for Skein's stated 128K-token context-window budget, and keep every
  complete Skein example compiling so agents can trust copy/pasted examples.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @pack_path Path.join(@repo_root, "docs/generated/skein-language-pack.md")
  @max_pack_bytes 128 * 1024 * 4

  test "language pack stays within the 128K-token context budget" do
    %{size: size} = File.stat!(@pack_path)

    assert size <= @max_pack_bytes,
           "#{Path.relative_to_cwd(@pack_path)} is #{size} bytes; budget is #{@max_pack_bytes} bytes (128K tokens × 4 bytes/token)"
  end

  test "complete Skein examples in the language pack compile without diagnostics" do
    content = File.read!(@pack_path)

    blocks =
      ~r/```skein\n(.*?)```/s
      |> Regex.scan(content)
      |> Enum.map(fn [_, code] -> code end)
      |> Enum.with_index()
      |> Enum.filter(fn {code, _index} -> complete_module?(code) end)

    assert length(blocks) >= 4,
           "expected the language pack to include canonical complete Skein examples"

    for {code, index} <- blocks do
      assert {:ok, %{errors: errors, warnings: warnings}} =
               Skein.Compiler.check_string(code, "docs/generated/skein-language-pack.md")

      assert errors == [],
             "language pack block ##{index} does not compile:\n" <>
               Enum.map_join(errors, "\n", &"  #{&1.code} line #{&1.location.line}: #{&1.message}")

      assert warnings == [],
             "language pack block ##{index} emits warnings:\n" <>
               Enum.map_join(warnings, "\n", &"  #{&1.code} line #{&1.location.line}: #{&1.message}")
    end
  end

  defp complete_module?(code) do
    first =
      code
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
      |> List.first()

    is_binary(first) and first =~ ~r/\Amodule [A-Z]\w* \{/ and not String.contains?(code, "...")
  end
end
