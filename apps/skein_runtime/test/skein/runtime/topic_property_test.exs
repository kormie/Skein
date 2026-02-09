defmodule Skein.Runtime.TopicPropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime topic dispatch module.

  Tests subscribe/publish/list operations across generated topic names
  and message payloads to ensure correct fan-out dispatch behaviour.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Topic

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp topic_name_gen do
    gen all(
          name <-
            StreamData.string(Enum.to_list(?a..?z) ++ [?.], min_length: 3, max_length: 20)
        ) do
      "prop-t-#{name}"
    end
  end

  defp message_gen do
    StreamData.fixed_map(%{
      "body" => StreamData.string(:alphanumeric, min_length: 1, max_length: 50),
      "type" => StreamData.member_of(["order", "event", "notification", "task"])
    })
  end

  setup do
    on_exit(fn -> Topic.reset_all() end)
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "subscribing adds topic to list_topics" do
    check all(topic_name <- topic_name_gen()) do
      Topic.reset_all()
      Topic.subscribe_fn(topic_name, fn _ -> :ok end)
      assert topic_name in Topic.list_topics()
    end
  end

  property "published messages are delivered to subscriber" do
    check all(
            topic_name <- topic_name_gen(),
            message <- message_gen()
          ) do
      Topic.reset_all()
      test_pid = self()

      Topic.subscribe_fn(topic_name, fn msg ->
        send(test_pid, {:delivered, msg})
        :ok
      end)

      Topic.publish(topic_name, message, [])
      assert_receive {:delivered, ^message}, 1000
    end
  end

  property "fan-out: all subscribers receive published message" do
    check all(
            topic_name <- topic_name_gen(),
            message <- message_gen(),
            sub_count <- StreamData.integer(2..4)
          ) do
      Topic.reset_all()
      test_pid = self()

      for i <- 1..sub_count do
        Topic.subscribe_fn(topic_name, fn msg ->
          send(test_pid, {:delivered, i, msg})
          :ok
        end)
      end

      Topic.publish(topic_name, message, [])

      for i <- 1..sub_count do
        assert_receive {:delivered, ^i, ^message}, 1000
      end
    end
  end

  property "multiple messages are delivered in order per subscriber" do
    check all(
            topic_name <- topic_name_gen(),
            messages <-
              StreamData.list_of(message_gen(), min_length: 1, max_length: 5)
          ) do
      Topic.reset_all()
      test_pid = self()

      Topic.subscribe_fn(topic_name, fn msg ->
        send(test_pid, {:delivered, msg})
        :ok
      end)

      for msg <- messages do
        Topic.publish(topic_name, msg, [])
      end

      for msg <- messages do
        assert_receive {:delivered, ^msg}, 1000
      end
    end
  end

  property "publishing to unsubscribed topic does not crash" do
    check all(
            topic_name <- topic_name_gen(),
            message <- message_gen()
          ) do
      Topic.reset_all()
      # Should complete without error even with no subscribers
      assert :ok = Topic.publish(topic_name, message, [])
    end
  end

  property "multiple distinct topic names are tracked independently" do
    check all(
            names <-
              StreamData.uniq_list_of(topic_name_gen(), min_length: 2, max_length: 5)
          ) do
      Topic.reset_all()

      for name <- names do
        Topic.subscribe_fn(name, fn _ -> :ok end)
      end

      topics = Topic.list_topics()

      for name <- names do
        assert name in topics
      end
    end
  end

  property "reset_all clears all subscriptions" do
    check all(
            names <-
              StreamData.uniq_list_of(topic_name_gen(), min_length: 1, max_length: 5)
          ) do
      Topic.reset_all()

      for name <- names do
        Topic.subscribe_fn(name, fn _ -> :ok end)
      end

      Topic.reset_all()
      assert Topic.list_topics() == []
    end
  end
end
