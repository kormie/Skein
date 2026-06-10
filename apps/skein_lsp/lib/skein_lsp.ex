defmodule SkeinLsp do
  @moduledoc """
  Entry point for the Skein Language Server.

  Start with stdio transport:

      skein lsp        # standalone binary
      mix skein.lsp    # inside a compiler checkout

  Or programmatically:

      SkeinLsp.start()
  """

  @doc """
  Starts the language server using stdio transport.

  Boots the full GenLSP process tree: the stdio buffer, the assigns
  store, the task supervisor for request handling, and the server
  itself. Returns `{:ok, pid}` for the server process.
  """
  @spec start() :: {:ok, pid()}
  def start do
    {:ok, buffer} =
      GenLSP.Buffer.start_link(communication: {GenLSP.Communication.Stdio, []})

    {:ok, assigns} = GenLSP.Assigns.start_link()
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, _pid} =
      GenLSP.start_link(Skein.Lsp.Server, [],
        buffer: buffer,
        assigns: assigns,
        task_supervisor: task_supervisor
      )
  end
end
