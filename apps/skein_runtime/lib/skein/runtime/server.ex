defmodule Skein.Runtime.Server do
  @moduledoc """
  HTTP server for Skein handler modules, powered by Bandit + Plug.

  Starts a Bandit HTTP server that routes requests through a Plug pipeline
  built from the compiled Skein module's handler declarations.

  ## Usage

      {:ok, pid} = Skein.Runtime.Server.start_link(
        module: Skein.User.MyService,
        port: 4000
      )

  The server will:
  1. Build a Plug router from `__handlers__/0` on the compiled module
  2. Start Bandit on the given port
  3. Dispatch requests to compiled Skein handlers
  4. Return JSON responses
  5. Serve trace data at `GET /__skein/traces`
  """

  use GenServer

  alias Skein.Runtime.Router

  @doc """
  Starts the HTTP server.

  Options:
  - `:module` — The compiled Skein module (required)
  - `:port` — Port to listen on (default: 4000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Stops the server.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    port = Keyword.get(opts, :port, 4000)

    router = Router.build(module)
    register_schedule_handlers(module)

    case Bandit.start_link(plug: router, port: port, ip: {127, 0, 0, 1}) do
      {:ok, bandit_pid} ->
        {:ok,
         %{
           module: module,
           port: port,
           bandit_pid: bandit_pid
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.bandit_pid) do
      Supervisor.stop(state.bandit_pid)
    end

    :ok
  end

  # Schedule handlers fire on the runtime's cron tick rather than via
  # HTTP routing — register each one so a running service auto-fires them.
  defp register_schedule_handlers(module) do
    if function_exported?(module, :__handlers__, 0) do
      module.__handlers__()
      |> Enum.filter(&(&1.source == :schedule))
      |> Enum.each(fn handler ->
        Skein.Runtime.Schedule.register(handler.route, module, handler.handler)
      end)
    end

    :ok
  end
end
