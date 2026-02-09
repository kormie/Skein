defmodule Skein.Runtime.MemoryStatemTest do
  @moduledoc """
  PropCheck stateful (state machine) test for Skein.Runtime.Memory.

  Models the memory store as a simple map and verifies that the ETS-backed
  implementation matches the model through randomly generated sequences of
  put, get, delete, and list operations.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.Memory
  alias Skein.Runtime.Trace

  @namespace "statem_test"
  @capabilities [%{kind: "memory.kv", params: [@namespace]}]

  # ------------------------------------------------------------------
  # Model state: a plain map representing expected key-value contents
  # ------------------------------------------------------------------

  def initial_state, do: %{}

  # ------------------------------------------------------------------
  # Command generation
  # ------------------------------------------------------------------

  def command(state) do
    always_available = [
      {:call, __MODULE__, :do_put, [key(), value()]},
      {:call, __MODULE__, :do_get, [key()]},
      {:call, __MODULE__, :do_delete, [key()]},
      {:call, __MODULE__, :do_list, [prefix()]}
    ]

    # If there are existing keys, bias towards operations on those keys
    existing_key_cmds =
      case Map.keys(state) do
        [] ->
          []

        keys ->
          [
            {:call, __MODULE__, :do_get, [oneof(keys)]},
            {:call, __MODULE__, :do_delete, [oneof(keys)]}
          ]
      end

    oneof(always_available ++ existing_key_cmds)
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp key do
    let k <- non_empty(utf8()) do
      k
    end
  end

  defp value do
    oneof([
      utf8(),
      integer(),
      bool(),
      list(integer())
    ])
  end

  defp prefix do
    oneof([
      utf8(),
      exactly("")
    ])
  end

  # ------------------------------------------------------------------
  # Command implementations (system under test)
  # ------------------------------------------------------------------

  def do_put(key, value) do
    Memory.put(@namespace, key, value, @capabilities)
  end

  def do_get(key) do
    Memory.get(@namespace, key, @capabilities)
  end

  def do_delete(key) do
    Memory.delete(@namespace, key, @capabilities)
  end

  def do_list(prefix) do
    Memory.list(@namespace, prefix, @capabilities)
  end

  # ------------------------------------------------------------------
  # Preconditions (always true for memory — all commands are valid)
  # ------------------------------------------------------------------

  def precondition(_state, {:call, _, _, _}), do: true

  # ------------------------------------------------------------------
  # Postconditions (verify real result matches model)
  # ------------------------------------------------------------------

  def postcondition(_state, {:call, _, :do_put, [_key, value]}, result) do
    result == {:ok, value}
  end

  def postcondition(state, {:call, _, :do_get, [key]}, result) do
    case Map.fetch(state, key) do
      {:ok, expected} -> result == {:ok, expected}
      :error -> result == {:error, "not_found"}
    end
  end

  def postcondition(_state, {:call, _, :do_delete, [key]}, result) do
    result == {:ok, key}
  end

  def postcondition(state, {:call, _, :do_list, [prefix]}, result) do
    expected =
      state
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()

    is_list(result) and Enum.sort(result) == expected
  end

  # ------------------------------------------------------------------
  # Next state (update the model)
  # ------------------------------------------------------------------

  def next_state(state, _result, {:call, _, :do_put, [key, value]}) do
    Map.put(state, key, value)
  end

  def next_state(state, _result, {:call, _, :do_get, [_key]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_delete, [key]}) do
    Map.delete(state, key)
  end

  def next_state(state, _result, {:call, _, :do_list, [_prefix]}) do
    state
  end

  # ------------------------------------------------------------------
  # Property
  # ------------------------------------------------------------------

  property "memory KV operations maintain consistency with model", [:verbose, {:numtests, 50}] do
    forall cmds <- commands(__MODULE__) do
      # Clean up before each test
      Memory.clear(@namespace)
      Trace.clear()

      {history, state, result} = run_commands(__MODULE__, cmds)

      # Clean up after
      Memory.clear(@namespace)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result)}
        """)
      )
    end
  end
end
