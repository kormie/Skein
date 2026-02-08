defmodule Skein.Runtime.AgentTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Agent, as: RuntimeAgent

  # Helper: compile a Skein agent source string and return the loaded module
  defp compile!(source) do
    case Skein.Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  describe "agent lifecycle" do
    test "agent starts and stops via phase transitions" do
      mod =
        compile!("""
        agent LifecycleAgent {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{})
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "agent can be queried for phase before terminal transition" do
      mod =
        compile!("""
        agent QueryableAgent {
          enum Phase {
            Waiting -> []
          }

          on start() -> {
            transition(Phase.Waiting)
          }

          on phase(Phase.Waiting) -> {
            -- keep state, do nothing (returns :keep)
            42
          }
        }
        """)

      {:ok, pid} = RuntimeAgent.start_link(mod, %{})
      # The agent should be in :waiting phase
      # Use gen_statem.call directly since the agent stays alive
      assert RuntimeAgent.get_phase(pid) == :waiting
      :gen_statem.stop(pid)
    end
  end

  describe "agent with multiple phases" do
    test "transitions through three phases" do
      mod =
        compile!("""
        agent MultiPhaseAgent {
          enum Phase {
            A -> [B]
            B -> [C]
            C -> []
          }

          on start() -> {
            transition(Phase.A)
          }

          on phase(Phase.A) -> {
            transition(Phase.B)
          }

          on phase(Phase.B) -> {
            transition(Phase.C)
          }

          on phase(Phase.C) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{})
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent with conditional transitions" do
    test "transitions based on match expression" do
      mod =
        compile!("""
        agent ConditionalAgent {
          enum Phase {
            Check -> [Pass, Fail]
            Pass -> []
            Fail -> []
          }

          on start() -> {
            transition(Phase.Check)
          }

          on phase(Phase.Check) -> {
            match 1 > 0 {
              true -> transition(Phase.Pass)
              false -> transition(Phase.Fail)
            }
          }

          on phase(Phase.Pass) -> {
            stop()
          }

          on phase(Phase.Fail) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{})
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent with start parameters" do
    test "receives parameters in start handler" do
      mod =
        compile!("""
        agent ParamLifecycleAgent {
          enum Phase {
            Ready -> []
          }

          on start(name: String, count: Int) -> {
            transition(Phase.Ready)
          }

          on phase(Phase.Ready) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{name: "test", count: 42})
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent user functions" do
    test "user functions are callable from outside the agent" do
      mod =
        compile!("""
        agent FnCallAgent {
          enum Phase {
            Init -> []
          }

          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            stop()
          }
        }
        """)

      assert mod.add(3, 4) == 7
      assert mod.greet("World") == "Hello, World!"
    end
  end
end
