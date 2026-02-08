defmodule Skein.CLI do
  @moduledoc """
  CLI entry point for Skein tooling.

  Provides commands for compiling Skein source files and running
  Skein test constructs.
  """

  alias Skein.Compiler

  @doc """
  Compiles a .skein file to BEAM bytecode and loads the resulting module.

  Returns `{:ok, module}` on success or `{:error, reason}` on failure.
  """
  @spec compile([String.t()]) :: {:ok, module()} | {:error, term()}
  def compile([]) do
    {:error, "Usage: skein compile <file.skein>"}
  end

  def compile([path | _]) do
    case Compiler.compile_file(path) do
      {:module, mod} -> {:ok, mod}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compiles a .skein file and runs all test declarations within it.

  Returns `{:ok, %{total: n, passed: n, failed: n, results: [...]}}`.
  """
  @spec test([String.t()]) :: {:ok, map()} | {:error, term()}
  def test([]) do
    {:error, "Usage: skein test <file.skein>"}
  end

  def test([path | _]) do
    case compile([path]) do
      {:ok, mod} ->
        run_tests(mod)

      {:error, _} = err ->
        err
    end
  end

  defp run_tests(mod) do
    tests =
      if function_exported?(mod, :__tests__, 0) do
        mod.__tests__()
      else
        []
      end

    results =
      Enum.map(tests, fn %{description: desc, fn: test_fn} ->
        try do
          apply(mod, test_fn, [])
          %{description: desc, status: :passed}
        rescue
          e ->
            %{description: desc, status: :failed, error: Exception.message(e)}
        end
      end)

    passed = Enum.count(results, &(&1.status == :passed))
    failed = Enum.count(results, &(&1.status == :failed))

    {:ok, %{total: length(results), passed: passed, failed: failed, results: results}}
  end
end
