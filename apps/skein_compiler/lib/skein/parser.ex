defmodule Skein.Parser do
  @moduledoc """
  Recursive descent parser for Skein.

  Converts a token list into an AST. Uses synchronization-point error
  recovery to report multiple errors per compilation.
  """

  @spec parse(list()) :: {:ok, Skein.AST.Module.t()} | {:error, [Skein.Error.t()]}
  def parse(_tokens) do
    # TODO: Implement parser
    {:error,
     [
       %Skein.Error{
         code: "E0001",
         severity: :error,
         message: "Parser not yet implemented",
         location: %{file: "unknown", line: 1, col: 1}
       }
     ]}
  end
end
