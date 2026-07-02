defmodule Skein.EffectABITest do
  @moduledoc """
  Invariants of the authoritative effect-ABI registry (C1/#296), plus the
  two-way spec §6 drift gate: every signature the registry pins must appear
  verbatim in SKEIN_SPEC.md §6, and every effect signature line in §6 must
  be pinned by the registry. Editing either side alone is a failure.
  """
  use ExUnit.Case, async: true

  alias Skein.EffectABI

  @spec_path Path.expand("../../../../docs/SKEIN_SPEC.md", __DIR__)

  describe "registry invariants" do
    test "entries are unique per {namespace, method}" do
      keys = Enum.map(EffectABI.entries(), &{&1.ns, &1.method})
      assert keys == Enum.uniq(keys)
    end

    test "only trailing params are optional" do
      for entry <- EffectABI.entries() do
        optional_flags = Enum.map(entry.params, & &1.optional)

        assert optional_flags == Enum.sort(optional_flags),
               "#{entry.ns}.#{entry.method}: an optional param precedes a required one"
      end
    end

    test "every entry names a runtime dispatch target and at least one spec line" do
      for entry <- EffectABI.entries() do
        assert {mod, fun} = entry.runtime
        assert is_atom(mod) and is_atom(fun)
        assert entry.spec_lines != [], "#{entry.ns}.#{entry.method} has no spec line"
        assert entry.dispatch in [:generic, :special]
      end
    end

    test "param names/types stay index-aligned in the derived views" do
      names = EffectABI.effect_param_names()
      types = EffectABI.effect_param_types()

      assert Map.keys(names) |> Enum.sort() == Map.keys(types) |> Enum.sort()

      for {key, name_list} <- names do
        assert length(name_list) == length(types[key]),
               "#{inspect(key)}: param names and types disagree in length"
      end
    end

    test "optional params reference declared param names" do
      names = EffectABI.effect_param_names()

      for {key, optional} <- EffectABI.effect_optional_params() do
        for opt <- optional do
          assert opt in names[key],
                 "#{inspect(key)}: optional #{opt} is not a declared param"
        end
      end
    end

    test "scoped-label kinds are exactly the compiler-threaded namespaces" do
      assert EffectABI.scoped_label_capability_kinds() == %{
               "process" => "process.spawn",
               "timer" => "timer",
               "event" => "event.log"
             }
    end

    test "generic runtime dispatch excludes the special-cased namespaces" do
      generic = EffectABI.generic_runtime_modules()
      refute Map.has_key?(generic, "memory")
      refute Map.has_key?(generic, "llm")
      refute Map.has_key?(generic, "tool")
    end

    test "provider contracts cover exactly the four runtime resolution points" do
      assert EffectABI.provider_contracts() |> Map.keys() |> Enum.sort() ==
               ["http.out", "instant", "model", "uuid"]
    end
  end

  describe "spec §6 drift (two-way)" do
    # Effect signature lines inside §6 code fences: `ns.method(...) -> ...`
    # (also matches `store.<table>.method(...)` and `llm.json[T](...)`).
    # Trailing `-- comment` annotations are stripped before comparison.
    defp spec_section_6 do
      content = File.read!(@spec_path)
      [_, section] = String.split(content, ~r/^## 6\. Effects API$/m, parts: 2)
      [section | _] = String.split(section, ~r/^## /m, parts: 2)
      section
    end

    defp spec_signature_lines do
      Regex.scan(~r/```\n(.*?)```/s, spec_section_6())
      |> Enum.flat_map(fn [_, block] -> String.split(block, "\n") end)
      |> Enum.map(&String.replace(&1, ~r/\s+--.*$/, ""))
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 =~ ~r/\A[a-z]\w*\.\S+\(.*\)\s*->/))
    end

    test "every registry signature appears verbatim in spec §6" do
      spec_lines = spec_signature_lines()

      for line <- EffectABI.spec_lines() do
        assert line in spec_lines,
               "registry pins \"#{line}\" but spec §6 does not contain it — " <>
                 "update SKEIN_SPEC.md §6 or the registry entry"
      end
    end

    test "every effect signature line in spec §6 is pinned by the registry" do
      registry_lines = EffectABI.spec_lines()

      for line <- spec_signature_lines() do
        assert line in registry_lines,
               "spec §6 documents \"#{line}\" but the registry does not pin it — " <>
                 "add/align the Skein.EffectABI entry"
      end
    end
  end
end
