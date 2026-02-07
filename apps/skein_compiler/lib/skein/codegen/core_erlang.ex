defmodule Skein.CodeGen.CoreErlang do
  @moduledoc """
  Code generator: Skein AST -> Core Erlang -> BEAM bytecode.

  Uses the :cerl module to build Core Erlang AST nodes programmatically,
  then calls :compile.forms/2 to produce .beam bytecode.
  """

  @spec generate(Skein.AST.Module.t()) :: {:ok, binary()} | {:error, [Skein.Error.t()]}
  def generate(_ast) do
    # TODO: Implement code generation
    {:error,
     [
       %Skein.Error{
         code: "E0001",
         severity: :error,
         message: "Code generator not yet implemented",
         location: %{file: "unknown", line: 1, col: 1}
       }
     ]}
  end
end
