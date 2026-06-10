defmodule Skein.Compiler do
  @moduledoc """
  Main entry point for the Skein compiler.

  Orchestrates the compilation pipeline:
  Source (.skein) -> Lexer -> Parser -> Analyzer -> CodeGen -> BEAM bytecode
  """

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer
  alias Skein.CodeGen.CoreErlang

  @spec compile_file(String.t()) ::
          {:module, module()} | {:error, [Skein.Error.t()] | String.t()}
  def compile_file(path) do
    with {:ok, source} <- read_source(path),
         {:ok, tokens} <- tag_errors(Lexer.tokenize(source), path),
         {:ok, ast} <- Parser.parse(tokens, path),
         {:ok, annotated_ast} <- normalize_analyze(Analyzer.analyze(ast, source_text: source)),
         {:ok, modules} <- CoreErlang.generate(annotated_ast) do
      load_modules(modules, ~c"#{path}")
    end
  end

  @spec compile_string(String.t()) :: {:module, module()} | {:error, [Skein.Error.t()]}
  def compile_string(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- normalize_analyze(Analyzer.analyze(ast, source_text: source)),
         {:ok, modules} <- CoreErlang.generate(annotated_ast) do
      load_modules(modules, ~c"nofile")
    end
  end

  @doc """
  Compiles a .skein file and returns the named BEAM binaries without
  loading them into the VM. Used by `skein build --output` to write
  .beam files to disk. The primary module is first; agents nested in
  the module follow.
  """
  @spec compile_to_binary(String.t()) ::
          {:ok, [{module(), binary()}]} | {:error, [Skein.Error.t()] | String.t()}
  def compile_to_binary(path) do
    with {:ok, source} <- read_source(path),
         {:ok, tokens} <- tag_errors(Lexer.tokenize(source), path),
         {:ok, ast} <- Parser.parse(tokens, path),
         {:ok, annotated_ast} <- normalize_analyze(Analyzer.analyze(ast, source_text: source)),
         {:ok, modules} <- CoreErlang.generate(annotated_ast) do
      {:ok, modules}
    end
  end

  # Load every generated module (primary first, then nested agents) and
  # return the primary in the classic {:module, name} shape.
  defp load_modules([{primary_name, _} | _] = modules, source_id) do
    Enum.reduce_while(modules, {:module, primary_name}, fn {name, binary}, acc ->
      case :code.load_binary(name, source_id, binary) do
        {:module, _} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, "Failed to load #{name}: #{inspect(reason)}"}}
      end
    end)
  end

  # Normalize analyzer results: {:ok, ast, warnings} -> {:ok, ast}
  defp normalize_analyze({:ok, ast, _warnings}), do: {:ok, ast}
  defp normalize_analyze(other), do: other

  # Read a source file, translating POSIX errors into readable messages
  defp read_source(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eisdir} ->
        {:error,
         "#{path} is a directory - pass a .skein file, or use 'skein build #{path}' to compile a project"}

      {:error, posix} ->
        {:error, "Cannot read #{path}: #{:file.format_error(posix)}"}
    end
  end

  # Lexer errors carry file: "unknown" — stamp them with the real path
  defp tag_errors({:error, errors}, path) when is_list(errors) do
    {:error, Enum.map(errors, &put_in(&1.location.file, path))}
  end

  defp tag_errors(other, _path), do: other
end
