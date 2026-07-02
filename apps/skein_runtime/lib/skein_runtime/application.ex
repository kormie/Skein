defmodule SkeinRuntime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Effect-backing processes are owned by the application supervisor so
    # they get proper restart semantics. Their ensure_started/0 fallbacks
    # remain only for environments where the app isn't started (--no-start).
    children = [
      # First: owns all named ETS tables, so sibling init/1 callbacks (and
      # everything after app start) can request tables that outlive callers.
      Skein.Runtime.EtsTables,
      # Owns the opt-in EventStore SQLite persistence lifecycle (#299).
      Skein.Runtime.EventStore.Persistence,
      Skein.Runtime.Process,
      Skein.Runtime.Queue,
      Skein.Runtime.Topic,
      Skein.Runtime.Schedule,
      Skein.Runtime.Timer
    ]

    opts = [strategy: :one_for_one, name: SkeinRuntime.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
