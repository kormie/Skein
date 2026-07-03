# Shared helper for test HTTP servers (#338): never pick a random port.
# Bind port 0 and read the OS-assigned port back, so concurrently running
# suites (or lingering listeners) can never collide with `:eaddrinuse`.
defmodule Skein.Runtime.TestPorts do
  @doc """
  Starts a Bandit server bound to an OS-assigned port on 127.0.0.1 and
  returns `{pid, port}`. Any `:port`/`:ip`/`:startup_log` in `opts` is
  overridden.
  """
  def start_bandit!(opts) do
    {:ok, pid} =
      opts
      |> Keyword.merge(port: 0, ip: {127, 0, 0, 1}, startup_log: false)
      |> Bandit.start_link()

    {pid, bandit_port(pid)}
  end

  @doc """
  Reads the OS-assigned port back from a running Bandit server (Bandit
  returns the ThousandIsland supervisor pid).
  """
  def bandit_port(bandit_pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit_pid)
    port
  end

  @doc """
  Reads the OS-assigned port back from a `Skein.Runtime.Server` started
  with `port: 0`.
  """
  def server_port(server) do
    %{bandit_pid: bandit_pid} = :sys.get_state(server)
    bandit_port(bandit_pid)
  end
end

ExUnit.start()
