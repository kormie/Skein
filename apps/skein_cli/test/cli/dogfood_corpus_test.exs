defmodule Skein.CLI.DogfoodCorpusTest do
  @moduledoc """
  The **dogfood conformance gate** (#262, Wave D): compiles, loads, and RUNS
  the checked-in reductions of the two external dogfood ports on every
  `mix test` — so every Skein PR executes real downstream programs, not just
  first-party examples.

  The corpus lives at `conformance/dogfood/<name>/` (a full `skein test`
  project each) and is pinned to an upstream revision in
  `conformance/dogfood.json`:

  - `dungeon` — kormie/skein-testing (HTTP + store + llm + tool.call through
    scenario envelopes)
  - `fablepool` — kormie/FablePool-skein (the reduced FablePool conformance
    program: deterministic string-fingerprint canonicalization, convergence,
    cascade invalidation, conflict resolution, provenance walk, capability
    grants/attestations/revocation — all as application code)

  Each project's declared `expected_tests` count is asserted exactly, so a
  file that silently stops compiling (API drift — e.g. the ambient
  `Uuid.new()` removal that broke both ports before this gate existed) can
  never fake green by running fewer tests. Compile failures print the full
  structured diagnostics.

  When a Skein change legitimately breaks the corpus: migrate the upstream
  port, bump its pin in dogfood.json, and refresh the checked-in copy in the
  same PR.
  """
  use ExUnit.Case, async: false

  alias Skein.CLI

  @corpus_dir Path.expand("../../../../conformance/dogfood", __DIR__)
  @pins_file Path.expand("../../../../conformance/dogfood.json", __DIR__)

  @pins @pins_file |> File.read!() |> Jason.decode!()

  setup do
    # `skein test` applies each project's skein.toml LLM profile, which
    # mutates the process-global backend — restore it afterwards.
    previous_backend = Skein.Runtime.Llm.get_backend()
    on_exit(fn -> Skein.Runtime.Llm.set_backend(previous_backend) end)
    :ok
  end

  test "every pinned project has a checked-in corpus copy and vice versa" do
    pinned = @pins["projects"] |> Map.keys() |> Enum.sort()

    checked_in =
      @corpus_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(@corpus_dir, &1)))
      |> Enum.sort()

    assert pinned == checked_in,
           "conformance/dogfood.json pins #{inspect(pinned)} but " <>
             "conformance/dogfood/ holds #{inspect(checked_in)} — keep them in sync"
  end

  for {name, pin} <- @pins["projects"] do
    @tag :dogfood
    @tag timeout: 120_000
    test "dogfood project runs green: #{name} (#{pin["repo"]})" do
      name = unquote(name)
      expected_tests = unquote(pin["expected_tests"])
      project_dir = Path.join(@corpus_dir, name)

      assert {:ok, result} = CLI.test_all([project_dir])

      if result.compile_failed != [] do
        details =
          Enum.map_join(result.compile_failed, "\n", fn %{file: file, errors: errors} ->
            rendered =
              Enum.map_join(errors, "\n", fn e ->
                "  #{e.code} #{e.location.file}:#{e.location.line}: #{e.message}"
              end)

            "#{file}:\n#{rendered}"
          end)

        flunk(
          "dogfood project '#{name}' no longer compiles against this revision " <>
            "(API drift — migrate the port, bump the pin, refresh the corpus copy):\n" <>
            details
        )
      end

      failed = Enum.filter(result.results, &(&1.status == :failed))

      assert failed == [],
             "dogfood project '#{name}' has failing tests:\n" <>
               Enum.map_join(failed, "\n", fn r ->
                 "  #{r.file} — #{r.name}: #{inspect(r[:error] || r)}"
               end)

      assert result.total == expected_tests,
             "dogfood project '#{name}' ran #{result.total} tests but the pin " <>
               "expects exactly #{expected_tests} — a file was silently skipped " <>
               "or the corpus copy drifted from conformance/dogfood.json"
    end
  end
end
