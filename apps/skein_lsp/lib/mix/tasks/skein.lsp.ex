defmodule Mix.Tasks.Skein.Lsp do
  @moduledoc """
  Starts the Skein Language Server using stdio transport.

  ## Usage

      mix skein.lsp

  The language server communicates via stdin/stdout using the
  Language Server Protocol (LSP). This is typically invoked by
  an editor extension, not run directly.
  """
  use Mix.Task

  @shortdoc "Start the Skein Language Server"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    SkeinLsp.start()

    # Keep the process alive
    Process.sleep(:infinity)
  end
end
