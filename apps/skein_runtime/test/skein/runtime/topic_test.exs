defmodule Skein.Runtime.TopicTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Topic

  setup do
    # Reset BEFORE each test as well as after: the Topic registry is
    # app-global, and other suites (e.g. compiled modules mounted by
    # ServerTest) can leave subscriptions behind. The list_topics/0
    # emptiness test below depends on this pre-test reset (#338).
    Topic.reset_all()
    on_exit(fn -> Topic.reset_all() end)
  end

  describe "subscribe/3" do
    test "subscribes a module handler to a topic" do
      assert :ok = Topic.subscribe("order.events", FakeModule, :__handler_0__)
    end

    test "multiple modules can subscribe to different topics" do
      assert :ok = Topic.subscribe("events-a", FakeModule, :__handler_0__)
      assert :ok = Topic.subscribe("events-b", FakeModule, :__handler_1__)
    end

    test "multiple modules can subscribe to the same topic" do
      assert :ok = Topic.subscribe("shared-topic", ModuleA, :__handler_0__)
      assert :ok = Topic.subscribe("shared-topic", ModuleB, :__handler_0__)
    end
  end

  describe "publish/3 - fan-out semantics" do
    test "publishes a message and dispatches to a single subscriber" do
      test_pid = self()

      handler_fn = fn msg ->
        send(test_pid, {:handled, msg})
        {:respond_json, 200, "ok"}
      end

      Topic.subscribe_fn("dispatch-test", handler_fn)

      Topic.publish("dispatch-test", %{body: "hello"}, [
        %{kind: "topic.publish", params: ["dispatch-test"]}
      ])

      assert_receive {:handled, %{body: "hello"}}, 1000
    end

    test "publishes a message to ALL subscribers (fan-out)" do
      test_pid = self()

      handler_a = fn msg ->
        send(test_pid, {:handler_a, msg.body})
        {:respond_json, 200, "ok"}
      end

      handler_b = fn msg ->
        send(test_pid, {:handler_b, msg.body})
        {:respond_json, 200, "ok"}
      end

      handler_c = fn msg ->
        send(test_pid, {:handler_c, msg.body})
        {:respond_json, 200, "ok"}
      end

      Topic.subscribe_fn("fan-out-test", handler_a)
      Topic.subscribe_fn("fan-out-test", handler_b)
      Topic.subscribe_fn("fan-out-test", handler_c)

      Topic.publish("fan-out-test", %{body: "broadcast"}, [
        %{kind: "topic.publish", params: ["fan-out-test"]}
      ])

      assert_receive {:handler_a, "broadcast"}, 1000
      assert_receive {:handler_b, "broadcast"}, 1000
      assert_receive {:handler_c, "broadcast"}, 1000
    end

    test "messages are delivered in order per subscriber" do
      test_pid = self()

      handler_fn = fn msg ->
        send(test_pid, {:handled, msg.body})
        {:respond_json, 200, "ok"}
      end

      Topic.subscribe_fn("order-test", handler_fn)

      Topic.publish("order-test", %{body: "first"}, [
        %{kind: "topic.publish", params: ["order-test"]}
      ])

      Topic.publish("order-test", %{body: "second"}, [
        %{kind: "topic.publish", params: ["order-test"]}
      ])

      Topic.publish("order-test", %{body: "third"}, [
        %{kind: "topic.publish", params: ["order-test"]}
      ])

      assert_receive {:handled, "first"}, 1000
      assert_receive {:handled, "second"}, 1000
      assert_receive {:handled, "third"}, 1000
    end

    test "message to unsubscribed topic is dropped" do
      # No subscriber for this topic — should not crash
      assert {:ok, _} =
               Topic.publish("nonexistent-topic", %{body: "dropped"}, [
                 %{kind: "topic.publish", params: ["nonexistent-topic"]}
               ])
    end

    test "subscribers to different topics only receive their messages" do
      test_pid = self()

      handler_a = fn msg ->
        send(test_pid, {:topic_a, msg.body})
        {:respond_json, 200, "ok"}
      end

      handler_b = fn msg ->
        send(test_pid, {:topic_b, msg.body})
        {:respond_json, 200, "ok"}
      end

      Topic.subscribe_fn("topic-a", handler_a)
      Topic.subscribe_fn("topic-b", handler_b)

      Topic.publish("topic-a", %{body: "only-a"}, [%{kind: "topic.publish", params: ["topic-a"]}])

      assert_receive {:topic_a, "only-a"}, 1000
      refute_receive {:topic_b, _}, 200
    end
  end

  describe "list_topics/0" do
    test "returns empty list when no topics" do
      assert Topic.list_topics() == []
    end

    test "returns subscribed topic names" do
      Topic.subscribe_fn("t1", fn _ -> :ok end)
      Topic.subscribe_fn("t2", fn _ -> :ok end)

      topics = Topic.list_topics()
      assert "t1" in topics
      assert "t2" in topics
    end
  end

  describe "reset_all/0" do
    test "clears all subscriptions" do
      Topic.subscribe_fn("a", fn _ -> :ok end)
      Topic.subscribe_fn("b", fn _ -> :ok end)

      # The Topic registry is app-global and async suites run concurrently,
      # so assert membership rather than a global count — a topic leaking in
      # from another suite must not flake this test.
      topics = Topic.list_topics()
      assert "a" in topics
      assert "b" in topics

      Topic.reset_all()

      topics_after = Topic.list_topics()
      refute "a" in topics_after
      refute "b" in topics_after
    end
  end
end
