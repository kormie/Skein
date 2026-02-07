defmodule Skein.CodeGen.SchemaGen do
  @moduledoc """
  Generates JSON Schemas from Skein type declarations.

  Used for:
  - LLM tool calling manifests
  - HTTP request/response validation
  - LLM constrained decoding (llm.json[T])
  """

  @spec to_json_schema(Skein.AST.TypeDecl.t()) :: map()
  def to_json_schema(%Skein.AST.TypeDecl{}) do
    # TODO: Implement schema generation
    %{}
  end
end
