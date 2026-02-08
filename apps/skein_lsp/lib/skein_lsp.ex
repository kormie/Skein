defmodule SkeinLsp do
  @moduledoc """
  Entry point for the Skein Language Server.

  Start with stdio transport:

      mix skein.lsp

  Or programmatically:

      SkeinLsp.start()
  """

  @doc """
  Starts the language server using stdio transport.
  """
  def start do
    {:ok, _pid} =
      GenLSP.start_link(Skein.Lsp.Server, [], communication: {GenLSP.Communication.Stdio, []})
  end
end
