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

  @spec compile_file(String.t()) :: {:module, module()} | {:error, [Skein.Error.t()]}
  def compile_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- Analyzer.analyze(ast),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"#{path}", beam_binary)
    end
  end

  @spec compile_string(String.t()) :: {:module, module()} | {:error, [Skein.Error.t()]}
  def compile_string(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- Analyzer.analyze(ast),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"nofile", beam_binary)
    end
  end

  defp module_name_from_ast(%Skein.AST.Module{name: name}),
    do: String.to_atom("Elixir.Skein.User.#{name}")

  defp module_name_from_ast(_), do: :skein_unknown
end
