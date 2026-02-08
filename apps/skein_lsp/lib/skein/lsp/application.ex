defmodule Skein.Lsp.Application do
  @moduledoc """
  OTP Application for the Skein Language Server.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: Skein.Lsp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
