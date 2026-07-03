defmodule Skein.Runtime.SupervisorHostTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventStore
  alias Skein.Runtime.Memory
  alias Skein.Runtime.SupervisorHost

  # Wildcard memory capability for reading the memory table from the test
  # process (outside any agent scope).
  @memory_caps [%{kind: "memory.kv", params: []}]

  setup do
    EventStore.clear()
    Memory.clear_all()
    :ok
  end

  # Helper: compile a Skein source string; returns the primary module
  # (nested agent modules are loaded alongside it).
  defp compile!(source) do
    case Skein.Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # Polls until fun.() returns a truthy value or the timeout elapses.
  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("wait_until timed out")
        else
          Process.sleep(10)
          do_wait_until(fun, deadline)
        end
    end
  end

  defp child_pids(sup) do
    sup
    |> Supervisor.which_children()
    |> Map.new(fn {id, pid, _type, _mods} -> {id, pid} end)
  end

  defp child_started_events do
    EventStore.query(kind: :supervisor, event: :child_started)
  end

  # A module with one supervised Worker agent that writes a memory marker
  # in its start handler, then parks in a Waiting phase.
  defp pool_source(module_name) do
    """
    module #{module_name} {
      supervisor Pool {
        child Worker
      }

      agent Worker {
        capability memory.kv

        enum Phase {
          Waiting -> []
        }

        on start() -> {
          memory.put("marker", "written")
          transition(Phase.Waiting)
        }

        on phase(Phase.Waiting) -> {
          42
        }
      }
    }
    """
  end

  describe "start_supervisors/1" do
    test "returns {:ok, []} for a module without supervisor declarations" do
      mod =
        compile!("""
        module SupHostNoSups {
          fn id(x: Int) -> Int { x }
        }
        """)

      assert {:ok, []} = SupervisorHost.start_supervisors(mod)
    end

    test "starts a declared supervisor with a running agent child" do
      mod = compile!(pool_source("SupHostBasic"))

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)
      assert Process.alive?(sup)

      assert [{_id, pid, :worker, _mods}] = Supervisor.which_children(sup)
      assert is_pid(pid) and Process.alive?(pid)

      # The child is the compiled nested agent, parked in its Waiting phase
      assert Skein.Runtime.Agent.get_phase(pid) == :waiting

      # A :supervisor/:child_started event was appended
      assert [event] = child_started_events()
      assert event.supervisor == "Pool"
      assert event.child == "Worker"

      Supervisor.stop(sup)
    end

    test "passes declared child args to the agent start handler" do
      mod =
        compile!("""
        module SupHostArgs {
          supervisor Pool {
            child Worker { n: 5 }
          }

          agent Worker {
            capability memory.kv

            enum Phase {
              Waiting -> []
            }

            on start(n: Int) -> {
              memory.put("n_value", n)
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }
        }
        """)

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)

      # From outside an agent process, list returns raw scoped keys
      # ("Worker:<instance>:n_value") — the value must be the declared 5.
      [key] = Memory.list("default", "", @memory_caps)
      scoped = "Worker:" <> _ = key
      assert String.ends_with?(scoped, ":n_value")
      assert {:ok, 5} = Memory.get("default", key, @memory_caps)

      Supervisor.stop(sup)
    end

    test "skips children whose target is not a compiled agent" do
      mod =
        compile!("""
        module SupHostUnknownChild {
          supervisor Pool {
            child NoSuchAgent
          }
        }
        """)

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)
      assert Supervisor.which_children(sup) == []

      assert [event] = EventStore.query(kind: :supervisor, event: :child_skipped)
      assert event.supervisor == "Pool"
      assert event.child == "NoSuchAgent"

      Supervisor.stop(sup)
    end
  end

  describe "crash recovery" do
    test "a killed child is restarted, visible in the trace, and memory survives" do
      mod = compile!(pool_source("SupHostRestart"))

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)
      assert [{_id, first_pid, _, _}] = Supervisor.which_children(sup)

      # The first instance's memory write, under its raw scoped key
      [first_key] = Memory.list("default", "", @memory_caps)
      assert {:ok, "written"} = Memory.get("default", first_key, @memory_caps)

      Process.exit(first_pid, :kill)

      new_pid =
        wait_until(fn ->
          case Supervisor.which_children(sup) do
            [{_id, pid, _, _}] when is_pid(pid) and pid != first_pid -> pid
            _ -> nil
          end
        end)

      assert Process.alive?(new_pid)

      # Restart #2 shows up as a second :child_started event
      wait_until(fn -> length(child_started_events()) == 2 end)

      # memory.kv data written BEFORE the crash is still readable: the
      # table is owned by the supervised EtsTables process, not the agent.
      assert {:ok, "written"} = Memory.get("default", first_key, @memory_caps)

      # The restarted instance wrote its own marker under a new scope too
      keys = Memory.list("default", "", @memory_caps)
      assert length(keys) == 2

      Supervisor.stop(sup)
    end

    test "declared max_restarts intensity shuts the supervisor down when exceeded" do
      mod =
        compile!("""
        module SupHostIntensity {
          supervisor Fragile {
            child Worker
            max_restarts: 1 per 1s
          }

          agent Worker {
            enum Phase {
              Waiting -> []
            }

            on start() -> {
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }
        }
        """)

      Process.flag(:trap_exit, true)

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)
      sup_ref = Process.monitor(sup)

      assert [{_id, first_pid, _, _}] = Supervisor.which_children(sup)
      Process.exit(first_pid, :kill)

      second_pid =
        wait_until(fn ->
          case Supervisor.which_children(sup) do
            [{_id, pid, _, _}] when is_pid(pid) and pid != first_pid -> pid
            _ -> nil
          end
        end)

      # Second kill within the 1s window exceeds max_restarts: 1 per 1s —
      # the supervisor itself gives up and exits.
      Process.exit(second_pid, :kill)

      assert_receive {:DOWN, ^sup_ref, :process, ^sup, :shutdown}, 2_000
    after
      Process.flag(:trap_exit, false)
    end

    test "one_for_all restarts every child when one crashes" do
      mod =
        compile!("""
        module SupHostAllForOne {
          supervisor Pair {
            child Left
            child Right
            strategy: one_for_all
          }

          agent Left {
            enum Phase {
              Waiting -> []
            }

            on start() -> {
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }

          agent Right {
            enum Phase {
              Waiting -> []
            }

            on start() -> {
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }
        }
        """)

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)

      before = child_pids(sup)
      assert map_size(before) == 2

      [victim_id | _] = Map.keys(before)
      Process.exit(Map.fetch!(before, victim_id), :kill)

      after_pids =
        wait_until(fn ->
          pids = child_pids(sup)

          if map_size(pids) == 2 and Enum.all?(pids, fn {_id, pid} -> is_pid(pid) end) and
               pids != before do
            pids
          end
        end)

      # BOTH children got new pids — one_for_all took down the sibling too
      for {id, old_pid} <- before do
        assert Map.fetch!(after_pids, id) != old_pid
      end

      Supervisor.stop(sup)
    end

    test "default one_for_one restarts only the crashed child" do
      mod =
        compile!("""
        module SupHostOneForOne {
          supervisor Pair {
            child Left
            child Right
          }

          agent Left {
            enum Phase {
              Waiting -> []
            }

            on start() -> {
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }

          agent Right {
            enum Phase {
              Waiting -> []
            }

            on start() -> {
              transition(Phase.Waiting)
            }

            on phase(Phase.Waiting) -> {
              42
            }
          }
        }
        """)

      assert {:ok, [sup]} = SupervisorHost.start_supervisors(mod)

      before = child_pids(sup)
      assert map_size(before) == 2

      [victim_id, survivor_id] = Map.keys(before)
      Process.exit(Map.fetch!(before, victim_id), :kill)

      wait_until(fn ->
        pids = child_pids(sup)
        is_pid(pids[victim_id]) and pids[victim_id] != before[victim_id]
      end)

      # The sibling kept its original pid
      assert child_pids(sup)[survivor_id] == before[survivor_id]

      Supervisor.stop(sup)
    end
  end

  describe "server integration" do
    test "Skein.Runtime.Server boots declared supervisors for mounted modules" do
      mod = compile!(pool_source("SupHostServer"))

      {:ok, server} = Skein.Runtime.Server.start_link(modules: [mod], port: 0)

      # The supervisor's agent child started under the server
      wait_until(fn -> child_started_events() != [] end)
      assert [event] = child_started_events()
      assert event.supervisor == "Pool"
      assert event.child == "Worker"

      Skein.Runtime.Server.stop(server)
    end
  end
end
