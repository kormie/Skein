defmodule Skein.Runtime.QueueStatemTest do
  @moduledoc """
  PropCheck stateful (state machine) test for Skein.Runtime.Queue.

  Models the queue dispatch system as a map of queue names to subscriber
  counts and verifies that subscribe, publish, list_queues, and reset
  operations maintain consistency.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.Queue

  # ------------------------------------------------------------------
  # Model state: %{queue_name => subscriber_count}
  # We track subscriber counts because we can't inspect the actual handlers.
  # ------------------------------------------------------------------

  def initial_state, do: %{}

  # ------------------------------------------------------------------
  # Command generation
  # ------------------------------------------------------------------

  def command(state) do
    always_available = [
      {:call, __MODULE__, :do_subscribe, [queue_name()]},
      {:call, __MODULE__, :do_list_queues, []},
      {:call, __MODULE__, :do_reset, []}
    ]

    # If queues exist, also test publishing to them
    existing_queue_cmds =
      case Map.keys(state) do
        [] ->
          []

        names ->
          [
            {:call, __MODULE__, :do_publish, [oneof(names), message()]},
            {:call, __MODULE__, :do_subscribe, [oneof(names)]}
          ]
      end

    # Also test publishing to non-existent queues
    publish_new = [{:call, __MODULE__, :do_publish, [queue_name(), message()]}]

    oneof(always_available ++ existing_queue_cmds ++ publish_new)
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp queue_name do
    let name <- non_empty(list(oneof([range(?a, ?z), exactly(?-)]))) do
      "statem-q-" <> List.to_string(name)
    end
  end

  defp message do
    let body <- utf8() do
      %{"body" => body, "type" => "test"}
    end
  end

  # ------------------------------------------------------------------
  # Command implementations
  # ------------------------------------------------------------------

  def do_subscribe(queue_name) do
    # Use a no-op function — we just care about subscription tracking
    Queue.subscribe_fn(queue_name, fn _msg -> :ok end)
  end

  def do_publish(queue_name, message) do
    Queue.publish(queue_name, message)
  end

  def do_list_queues do
    Queue.list_queues()
  end

  def do_reset do
    Queue.reset_all()
  end

  # ------------------------------------------------------------------
  # Preconditions
  # ------------------------------------------------------------------

  def precondition(_state, {:call, _, _, _}), do: true

  # ------------------------------------------------------------------
  # Postconditions
  # ------------------------------------------------------------------

  def postcondition(_state, {:call, _, :do_subscribe, [_name]}, result) do
    result == :ok
  end

  def postcondition(_state, {:call, _, :do_publish, [_name, _msg]}, result) do
    result == :ok
  end

  def postcondition(state, {:call, _, :do_list_queues, []}, result) do
    expected = Map.keys(state) |> Enum.sort()
    is_list(result) and Enum.sort(result) == expected
  end

  def postcondition(_state, {:call, _, :do_reset, []}, result) do
    result == :ok
  end

  # ------------------------------------------------------------------
  # Next state
  # ------------------------------------------------------------------

  def next_state(state, _result, {:call, _, :do_subscribe, [name]}) do
    Map.update(state, name, 1, &(&1 + 1))
  end

  def next_state(state, _result, {:call, _, :do_publish, [_name, _msg]}) do
    state
  end

  def next_state(state, _result, {:call, _, :do_list_queues, []}) do
    state
  end

  def next_state(_state, _result, {:call, _, :do_reset, []}) do
    %{}
  end

  # ------------------------------------------------------------------
  # Property
  # ------------------------------------------------------------------

  property "queue operations maintain consistency with model", [:verbose, {:numtests, 50}] do
    forall cmds <- commands(__MODULE__) do
      Queue.reset_all()

      {history, state, result} = run_commands(__MODULE__, cmds)

      Queue.reset_all()

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
