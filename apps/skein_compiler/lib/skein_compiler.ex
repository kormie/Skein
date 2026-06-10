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
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"#{path}", beam_binary)
    end
  end

  @spec compile_string(String.t()) :: {:module, module()} | {:error, [Skein.Error.t()]}
  def compile_string(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- normalize_analyze(Analyzer.analyze(ast, source_text: source)),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"nofile", beam_binary)
    end
  end

  @doc """
  Compiles a .skein file and returns the module name and BEAM binary
  without loading it into the VM. Used by `skein build --output` to
  write .beam files to disk.
  """
  @spec compile_to_binary(String.t()) ::
          {:ok, module(), binary()} | {:error, [Skein.Error.t()] | String.t()}
  def compile_to_binary(path) do
    with {:ok, source} <- read_source(path),
         {:ok, tokens} <- tag_errors(Lexer.tokenize(source), path),
         {:ok, ast} <- Parser.parse(tokens, path),
         {:ok, annotated_ast} <- normalize_analyze(Analyzer.analyze(ast, source_text: source)),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      {:ok, module_name, beam_binary}
    end
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

  defp module_name_from_ast(%Skein.AST.Module{name: name}),
    do: String.to_atom("Elixir.Skein.User.#{name}")

  defp module_name_from_ast(%Skein.AST.Agent{name: name}),
    do: String.to_atom("Elixir.Skein.Agent.#{name}")

  defp module_name_from_ast(_), do: :skein_unknown
end
