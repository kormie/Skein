defmodule Skein.Runtime.CapabilityStackTest do
  @moduledoc """
  Tests for the dynamic scenario capability-context stack (#282 foundation),
  including a PropCheck stateful model of the push/pop discipline.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.CapabilityStack, as: Stack

  setup do
    Stack.clear()
    on_exit(&Stack.clear/0)
    :ok
  end

  # ------------------------------------------------------------------
  # Unit tests
  # ------------------------------------------------------------------

  describe "push/pop/current/depth" do
    test "an empty stack has no current envelope and depth 0" do
      assert Stack.current() == nil
      assert Stack.depth() == 0
      assert Stack.pop() == nil
    end

    test "push then current/depth reflect the top" do
      env = %{tool: "T", providers: %{}, nested: %{}}
      assert :ok = Stack.push(env)
      assert Stack.current() == env
      assert Stack.depth() == 1
    end

    test "pop returns and removes the top" do
      a = %{tool: "A"}
      b = %{tool: "B"}
      Stack.push(a)
      Stack.push(b)
      assert Stack.current() == b
      assert Stack.pop() == b
      assert Stack.current() == a
      assert Stack.depth() == 1
    end
  end

  describe "with_envelope" do
    test "restores the stack after the function returns" do
      assert Stack.depth() == 0

      result =
        Stack.with_envelope(%{tool: "T"}, fn ->
          assert Stack.current() == %{tool: "T"}
          assert Stack.depth() == 1
          :body_result
        end)

      assert result == :body_result
      assert Stack.depth() == 0
    end

    test "pops even when the body raises" do
      assert catch_throw(Stack.with_envelope(%{tool: "T"}, fn -> throw(:boom) end)) == :boom

      assert Stack.depth() == 0
    end

    test "nests correctly" do
      Stack.with_envelope(%{tool: "Outer"}, fn ->
        Stack.with_envelope(%{tool: "Inner"}, fn ->
          assert Stack.current() == %{tool: "Inner"}
          assert Stack.depth() == 2
        end)

        assert Stack.current() == %{tool: "Outer"}
        assert Stack.depth() == 1
      end)
    end
  end

  describe "resolve / nested_envelope" do
    test "resolve returns the installed provider for an effect key" do
      provider = fn -> "id-1" end
      Stack.push(%{tool: "T", providers: %{"uuid" => provider}})
      assert {:implement, ^provider} = Stack.resolve("uuid")
    end

    test "resolve returns :no_provider when the effect has none" do
      Stack.push(%{tool: "T", providers: %{"uuid" => fn -> :x end}})
      assert Stack.resolve("http.out") == :no_provider
    end

    test "resolve returns :no_provider with no active envelope" do
      assert Stack.resolve("uuid") == :no_provider
    end

    test "nested_envelope reads the active envelope's nested map" do
      nested = %{tool: "Other"}
      Stack.push(%{tool: "T", nested: %{"Other" => nested}})
      assert Stack.nested_envelope("Other") == nested
      assert Stack.nested_envelope("Missing") == nil
    end
  end

  describe "snapshot/restore (spawned-work hand-off)" do
    test "a snapshot can be restored in another logical context" do
      Stack.push(%{tool: "A"})
      Stack.push(%{tool: "B"})
      snap = Stack.snapshot()

      Stack.clear()
      assert Stack.depth() == 0

      Stack.restore(snap)
      assert Stack.depth() == 2
      assert Stack.current() == %{tool: "B"}
    end
  end

  # ------------------------------------------------------------------
  # PropCheck stateful model: push/pop discipline
  # ------------------------------------------------------------------

  property "the live stack matches a model under random push/pop sequences", numtests: 200 do
    forall cmds <- commands(__MODULE__) do
      Stack.clear()
      {history, _state, result} = run_commands(__MODULE__, cmds)
      Stack.clear()

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history)}
        Result: #{inspect(result)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # Model state is the list of envelopes (top first), mirroring the real stack.
  @impl true
  def initial_state, do: []

  @impl true
  def command(_state) do
    oneof([
      {:call, Stack, :push, [envelope_gen()]},
      {:call, Stack, :pop, []},
      {:call, Stack, :current, []},
      {:call, Stack, :depth, []}
    ])
  end

  @impl true
  def precondition(_state, _call), do: true

  @impl true
  def postcondition(state, {:call, Stack, :depth, []}, result), do: result == length(state)
  def postcondition(state, {:call, Stack, :current, []}, result), do: result == List.first(state)
  def postcondition(state, {:call, Stack, :pop, []}, result), do: result == List.first(state)
  def postcondition(_state, {:call, Stack, :push, _}, result), do: result == :ok
  def postcondition(_state, _call, _result), do: true

  @impl true
  def next_state(state, _result, {:call, Stack, :push, [env]}), do: [env | state]
  def next_state([], _result, {:call, Stack, :pop, []}), do: []
  def next_state([_top | rest], _result, {:call, Stack, :pop, []}), do: rest
  def next_state(state, _result, _call), do: state

  defp envelope_gen do
    let tool <- oneof(["A", "B", "C"]) do
      %{tool: tool, providers: %{}, nested: %{}}
    end
  end
end
