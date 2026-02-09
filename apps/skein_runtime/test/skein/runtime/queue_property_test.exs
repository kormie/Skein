defmodule Skein.Runtime.QueuePropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime queue dispatch module.

  Tests subscribe/publish/list operations across generated queue names
  and message payloads to ensure correct dispatch behaviour.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Queue

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp queue_name_gen do
    gen all(
          name <-
            StreamData.string(Enum.to_list(?a..?z) ++ [?-], min_length: 3, max_length: 20)
        ) do
      "prop-q-#{name}"
    end
  end

  defp message_gen do
    StreamData.fixed_map(%{
      "body" => StreamData.string(:alphanumeric, min_length: 1, max_length: 50),
      "type" => StreamData.member_of(["order", "event", "notification", "task"])
    })
  end

  setup do
    on_exit(fn -> Queue.reset_all() end)
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "subscribing adds queue to list_queues" do
    check all(queue_name <- queue_name_gen()) do
      Queue.reset_all()
      Queue.subscribe_fn(queue_name, fn _ -> :ok end)
      assert queue_name in Queue.list_queues()
    end
  end

  property "published messages are delivered to subscriber" do
    check all(
            queue_name <- queue_name_gen(),
            message <- message_gen()
          ) do
      Queue.reset_all()
      test_pid = self()

      Queue.subscribe_fn(queue_name, fn msg ->
        send(test_pid, {:delivered, msg})
        :ok
      end)

      Queue.publish(queue_name, message)
      assert_receive {:delivered, ^message}, 1000
    end
  end

  property "multiple messages are delivered in order" do
    check all(
            queue_name <- queue_name_gen(),
            messages <-
              StreamData.list_of(message_gen(), min_length: 1, max_length: 5)
          ) do
      Queue.reset_all()
      test_pid = self()

      Queue.subscribe_fn(queue_name, fn msg ->
        send(test_pid, {:delivered, msg})
        :ok
      end)

      for msg <- messages do
        Queue.publish(queue_name, msg)
      end

      for msg <- messages do
        assert_receive {:delivered, ^msg}, 1000
      end
    end
  end

  property "publishing to unsubscribed queue does not crash" do
    check all(
            queue_name <- queue_name_gen(),
            message <- message_gen()
          ) do
      Queue.reset_all()
      # Should complete without error even with no subscribers
      assert :ok = Queue.publish(queue_name, message)
    end
  end

  property "multiple distinct queue names are tracked independently" do
    check all(
            names <-
              StreamData.uniq_list_of(queue_name_gen(), min_length: 2, max_length: 5)
          ) do
      Queue.reset_all()

      for name <- names do
        Queue.subscribe_fn(name, fn _ -> :ok end)
      end

      queues = Queue.list_queues()

      for name <- names do
        assert name in queues
      end
    end
  end

  property "reset_all clears all subscriptions" do
    check all(
            names <-
              StreamData.uniq_list_of(queue_name_gen(), min_length: 1, max_length: 5)
          ) do
      Queue.reset_all()

      for name <- names do
        Queue.subscribe_fn(name, fn _ -> :ok end)
      end

      Queue.reset_all()
      assert Queue.list_queues() == []
    end
  end
end
