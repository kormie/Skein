defmodule Skein.Runtime.QueueTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Queue

  setup do
    # Clean up any leftover queues between tests
    on_exit(fn -> Queue.reset_all() end)
  end

  describe "subscribe/3" do
    test "subscribes a module handler to a queue" do
      assert :ok = Queue.subscribe("test-events", FakeModule, :__handler_0__)
    end

    test "multiple modules can subscribe to different queues" do
      assert :ok = Queue.subscribe("events-a", FakeModule, :__handler_0__)
      assert :ok = Queue.subscribe("events-b", FakeModule, :__handler_1__)
    end
  end

  describe "publish/2 and dispatch" do
    test "publishes a message and dispatches to subscriber" do
      # Create a simple test module that records calls
      test_pid = self()

      handler_fn = fn msg ->
        send(test_pid, {:handled, msg})
        {:respond_json, 200, "ok"}
      end

      Queue.subscribe_fn("dispatch-test", handler_fn)
      Queue.publish("dispatch-test", %{body: "hello"})

      assert_receive {:handled, %{body: "hello"}}, 1000
    end

    test "messages are delivered in order" do
      test_pid = self()

      handler_fn = fn msg ->
        send(test_pid, {:handled, msg.body})
        {:respond_json, 200, "ok"}
      end

      Queue.subscribe_fn("order-test", handler_fn)
      Queue.publish("order-test", %{body: "first"})
      Queue.publish("order-test", %{body: "second"})
      Queue.publish("order-test", %{body: "third"})

      assert_receive {:handled, "first"}, 1000
      assert_receive {:handled, "second"}, 1000
      assert_receive {:handled, "third"}, 1000
    end

    test "message to unsubscribed queue is dropped" do
      # No subscriber for this queue — should not crash
      assert :ok = Queue.publish("nonexistent-queue", %{body: "dropped"})
    end
  end

  describe "publish/3 capability checking" do
    test "publishes when the queue name is declared" do
      test_pid = self()
      Queue.subscribe_fn("caps-jobs", fn msg -> send(test_pid, {:got, msg}) end)

      caps = [%{kind: "queue.publish", params: ["caps-jobs"]}]
      assert :ok = Queue.publish("caps-jobs", %{body: "x"}, caps)
      assert_receive {:got, %{body: "x"}}, 1000
    end

    test "parameterless capability permits any queue name" do
      caps = [%{kind: "queue.publish", params: []}]
      assert :ok = Queue.publish("any-queue", %{body: "x"}, caps)
    end

    test "rejects publish without a queue.publish capability" do
      assert {:error, message} = Queue.publish("caps-jobs", %{body: "x"}, [])
      assert message =~ "queue.publish"
    end

    test "rejects publish to an undeclared queue name" do
      caps = [%{kind: "queue.publish", params: ["other-queue"]}]
      assert {:error, message} = Queue.publish("caps-jobs", %{body: "x"}, caps)
      assert message =~ "caps-jobs"
    end
  end

  describe "list_queues/0" do
    test "returns empty list when no queues" do
      assert Queue.list_queues() == []
    end

    test "returns subscribed queue names" do
      Queue.subscribe_fn("q1", fn _ -> :ok end)
      Queue.subscribe_fn("q2", fn _ -> :ok end)

      queues = Queue.list_queues()
      assert "q1" in queues
      assert "q2" in queues
    end
  end
end
