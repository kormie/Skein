defmodule Skein.Runtime.TopicStatemTest do
  @moduledoc """
  PropCheck stateful (state machine) test for Skein.Runtime.Topic.

  Models the topic dispatch system as a map of topic names to subscriber
  counts and verifies that subscribe, publish, list_topics, and reset
  operations maintain consistency.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM

  alias Skein.Runtime.Topic

  # ------------------------------------------------------------------
  # Model state: %{topic_name => subscriber_count}
  # We track subscriber counts because we can't inspect the actual handlers.
  # ------------------------------------------------------------------

  def initial_state, do: %{}

  # ------------------------------------------------------------------
  # Command generation
  # ------------------------------------------------------------------

  def command(state) do
    always_available = [
      {:call, __MODULE__, :do_subscribe, [topic_name()]},
      {:call, __MODULE__, :do_list_topics, []},
      {:call, __MODULE__, :do_reset, []}
    ]

    # If topics exist, also test publishing to them
    existing_topic_cmds =
      case Map.keys(state) do
        [] ->
          []

        names ->
          [
            {:call, __MODULE__, :do_publish, [oneof(names), message()]},
            {:call, __MODULE__, :do_subscribe, [oneof(names)]}
          ]
      end

    # Also test publishing to non-existent topics
    publish_new = [{:call, __MODULE__, :do_publish, [topic_name(), message()]}]

    oneof(always_available ++ existing_topic_cmds ++ publish_new)
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp topic_name do
    let name <- non_empty(list(oneof([range(?a, ?z), exactly(?.), exactly(?-)]))) do
      "statem-t-" <> List.to_string(name)
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

  def do_subscribe(topic_name) do
    # Use a no-op function — we just care about subscription tracking
    Topic.subscribe_fn(topic_name, fn _msg -> :ok end)
  end

  def do_publish(topic_name, message) do
    Topic.publish(topic_name, message, [%{kind: "topic.publish", params: []}])
  end

  def do_list_topics do
    Topic.list_topics()
  end

  def do_reset do
    Topic.reset_all()
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

  def postcondition(state, {:call, _, :do_list_topics, []}, result) do
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

  def next_state(state, _result, {:call, _, :do_list_topics, []}) do
    state
  end

  def next_state(_state, _result, {:call, _, :do_reset, []}) do
    %{}
  end

  # ------------------------------------------------------------------
  # Property
  # ------------------------------------------------------------------

  property "topic operations maintain consistency with model", [:verbose, {:numtests, 50}] do
    forall cmds <- commands(__MODULE__) do
      Topic.reset_all()

      {history, state, result} = run_commands(__MODULE__, cmds)

      Topic.reset_all()

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
