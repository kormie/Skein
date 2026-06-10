defmodule Skein.Runtime.AgentEventStoreTest do
  @moduledoc """
  Agent `emit` events flush to the EventStore (issue #72): events are
  appended as `:user_event` records after each handler completes, tagged
  with agent name, instance id, and phase — so they survive crashes and
  are visible to `EventStore.query/1`.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Agent, as: RuntimeAgent
  alias Skein.Runtime.EventStore

  defp compile!(source) do
    case Skein.Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  defp await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2_000 -> flunk("agent did not terminate")
    end
  end

  setup do
    EventStore.clear()
    :ok
  end

  test "emitted events appear in the EventStore tagged with agent, instance, and phase" do
    mod =
      compile!("""
      agent Emitter {
        state { topic: String }

        enum Phase {
          Working -> [Done]
          Done -> []
        }

        on start(topic: String) -> {
          emit Started { topic: topic }
          transition(Phase.Working)
        }

        on phase(Phase.Working) -> {
          emit Progress { step: "one" }
          emit Progress { step: "two" }
          transition(Phase.Done)
        }

        on phase(Phase.Done) -> {
          stop()
        }
      }
      """)

    {:ok, pid} = RuntimeAgent.start_link(mod, %{topic: "alpha"})
    await_exit(pid)

    events = EventStore.query(kind: :user_event)
    started = Enum.filter(events, &(&1.event == "Started"))
    progress = Enum.filter(events, &(&1.event == "Progress"))

    assert length(started) == 1
    assert length(progress) == 2

    [started_event] = started
    assert started_event.agent == "Emitter"
    assert is_binary(started_event.instance_id)
    assert started_event.phase == :start
    assert started_event.data == %{topic: "alpha"}

    assert Enum.all?(progress, &(&1.phase == :working))
  end

  test "events emitted before a crash survive in the EventStore" do
    mod =
      compile!("""
      agent Crasher {
        capability memory.kv("crasher")

        state { x: String }

        enum Phase {
          Emitting -> [Exploding]
          Exploding -> []
        }

        on start(x: String) -> {
          transition(Phase.Emitting)
        }

        on phase(Phase.Emitting) -> {
          emit BeforeCrash { x: "survived" }
          transition(Phase.Exploding)
        }

        on phase(Phase.Exploding) -> {
          let boom = memory.get!("no_such_key")
          stop()
        }
      }
      """)

    Process.flag(:trap_exit, true)
    {:ok, pid} = RuntimeAgent.start_link(mod, %{x: "v"})
    await_exit(pid)
    Process.flag(:trap_exit, false)

    events = EventStore.query(kind: :user_event, event: "BeforeCrash")
    assert [%{phase: :emitting, data: %{x: "survived"}}] = events
  end

  property "N events across M transitions yield exactly N user events in the store" do
    check all(
            emit_counts <- StreamData.list_of(StreamData.integer(0..3), length: 3),
            max_runs: 10
          ) do
      EventStore.clear()

      phases = ["P1", "P2", "P3"]
      transitions = ["P1 -> [P2]", "P2 -> [P3]", "P3 -> []"]

      phase_handlers =
        phases
        |> Enum.zip(emit_counts)
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {{phase, count}, index} ->
          emits =
            Enum.map_join(1..count//1, "\n", fn i ->
              ~s(    emit PropEvt { tag: "#{phase}-#{i}" })
            end)

          terminal =
            if index == length(phases) - 1 do
              "    stop()"
            else
              "    transition(Phase.#{Enum.at(phases, index + 1)})"
            end

          """
            on phase(Phase.#{phase}) -> {
          #{emits}
          #{terminal}
            }
          """
        end)

      mod =
        compile!("""
        agent PropEmitter {
          state { x: String }

          enum Phase {
            #{Enum.join(transitions, "\n    ")}
          }

          on start(x: String) -> {
            transition(Phase.P1)
          }

        #{phase_handlers}
        }
        """)

      {:ok, pid} = RuntimeAgent.start_link(mod, %{x: "v"})
      await_exit(pid)

      stored = EventStore.query(kind: :user_event, event: "PropEvt")
      assert length(stored) == Enum.sum(emit_counts)
    end
  end
end
