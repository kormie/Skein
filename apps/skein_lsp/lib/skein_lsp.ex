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

  Boots the GenLSP process tree (stdio buffer, assigns store, task
  supervisor, and the server itself) under a `:one_for_all` supervisor,
  so a crash in any part restarts the server instead of taking down
  the whole VM. Returns `{:ok, pid}` for the supervisor.
  """
  @spec start() :: {:ok, pid()}
  def start do
    children = [
      {GenLSP.Buffer,
       name: SkeinLsp.Buffer, communication: {GenLSP.Communication.Stdio, []}},
      %{
        id: GenLSP.Assigns,
        start: {GenLSP.Assigns, :start_link, [[name: SkeinLsp.Assigns]]}
      },
      {Task.Supervisor, name: SkeinLsp.TaskSupervisor},
      {Skein.Lsp.Server,
       name: SkeinLsp.Server,
       buffer: SkeinLsp.Buffer,
       assigns: SkeinLsp.Assigns,
       task_supervisor: SkeinLsp.TaskSupervisor}
    ]

    {:ok, _pid} =
      Supervisor.start_link(children, strategy: :one_for_all, name: SkeinLsp.TreeSupervisor)
  end
end
