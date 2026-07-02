defmodule Skein.Conformance.PositiveCorpusTest do
  @moduledoc """
  The **positive-fixture corpus** for the B4 soundness bridge (#293): every
  `*.skein` file under `conformance/positive/` is a program the analyzer MUST
  accept — and acceptance must carry all the way through Core Erlang
  generation, `:compile.forms/2`, and module load. A fixture that exports a
  pure `main/0` is also executed.

  This is the table-driven half of the gate; the generated half lives in
  `codegen_soundness_property_test.exs`. Adding a fixture file automatically
  adds a test — no code change required.
  """
  use ExUnit.Case, async: true

  @fixtures_dir Path.join(__DIR__, "positive")
  @fixtures Path.wildcard(Path.join(@fixtures_dir, "*.skein"))

  test "the corpus is non-empty (guards against a glob/path regression)" do
    assert length(@fixtures) >= 6,
           "expected the positive corpus to hold the B4 accepted-program fixtures"
  end

  for fixture <- @fixtures do
    name = Path.basename(fixture)

    @tag :conformance
    test "positive fixture compiles, loads, and runs: #{name}" do
      case Skein.Compiler.compile_file(unquote(fixture)) do
        {:module, mod} ->
          assert Code.ensure_loaded?(mod)

          if function_exported?(mod, :main, 0) do
            mod.main()
          end

        {:error, errors} ->
          flunk("""
          positive fixture #{unquote(name)} must compile and load, got:

          #{inspect(Enum.map(errors, &{&1.code, &1.message}), pretty: true)}
          """)
      end
    end
  end
end
