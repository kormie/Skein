defmodule Skein.Runtime.UnifiedEventsTest do
  @moduledoc """
  Integration tests verifying the unified event architecture.

  Tests that Trace, EventStore.log, and Memory all write to the same
  EventStore, and that memory state can be reconstructed from the event stream.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventStore
  alias Skein.Runtime.Memory
  alias Skein.Runtime.Trace
  alias Skein.Runtime.Replay

  @namespace "unified_test"
  @caps [%{kind: "memory.kv", params: ["unified_test"]}]

  setup do
    EventStore.clear()
    Memory.clear(@namespace)
    :ok
  end

  # ------------------------------------------------------------------
  # All events flow through one store
  # ------------------------------------------------------------------

  describe "unified event stream" do
    test "trace spans, user events, and memory changes all appear in one stream" do
      # Record a trace span
      Trace.record_span(%{kind: :http, method: :get, url: "/test"})

      # Log a user event
      EventStore.log(nil, "user.action", %{action: "click"}, [%{kind: "event.log", params: []}])

      # Perform a memory operation (produces both :memory effect span + :state_change)
      Memory.put(@namespace, "key1", "value1", @caps)

      # Add a trace annotation
      Trace.annotate("step", "done")

      events = EventStore.all()

      # Should have at least 4 events (http + user_event + memory effect + state_change + annotation)
      assert length(events) >= 4

      kinds = Enum.map(events, & &1.kind)
      assert :http in kinds
      assert :user_event in kinds
      assert :state_change in kinds
      assert :annotation in kinds
    end

    test "events are queryable by kind across the unified stream" do
      Trace.record_span(%{kind: :http, method: :get, url: "/a"})
      EventStore.log(nil, "login", %{}, [%{kind: "event.log", params: []}])
      Memory.put(@namespace, "k", "v", @caps)
      Trace.annotate("tag", "value")

      assert length(EventStore.query(kind: :http)) == 1
      assert length(EventStore.query(kind: :user_event)) == 1
      assert length(EventStore.query(kind: :state_change)) == 1
      assert length(EventStore.query(kind: :annotation)) == 1
    end

    test "snapshot captures full event stream in chronological order" do
      Trace.record_span(%{kind: :http, method: :get, url: "/first"})
      EventStore.log(nil, "middle", %{}, [%{kind: "event.log", params: []}])
      Memory.put(@namespace, "last", "v", @caps)

      snapshot = EventStore.snapshot()

      # Chronological — oldest first
      timestamps = Enum.map(snapshot, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :asc)

      # Contains all event kinds
      kinds = Enum.map(snapshot, & &1.kind)
      assert :http in kinds
      assert :user_event in kinds
    end
  end

  # ------------------------------------------------------------------
  # Memory reconstruction from events
  # ------------------------------------------------------------------

  describe "memory reconstruction from event stream" do
    test "rebuild_from_events matches live ETS state after puts" do
      Memory.put(@namespace, "user_id", "u-123", @caps)
      Memory.put(@namespace, "session", "s-456", @caps)
      Memory.put(@namespace, "preference", "dark", @caps)

      # Live state from ETS
      assert {:ok, "u-123"} = Memory.get(@namespace, "user_id", @caps)
      assert {:ok, "s-456"} = Memory.get(@namespace, "session", @caps)
      assert {:ok, "dark"} = Memory.get(@namespace, "preference", @caps)

      # Reconstructed state from events
      rebuilt = Memory.rebuild_from_events(@namespace)
      assert rebuilt["user_id"] == "u-123"
      assert rebuilt["session"] == "s-456"
      assert rebuilt["preference"] == "dark"
    end

    test "rebuild_from_events handles overwrites" do
      Memory.put(@namespace, "counter", 1, @caps)
      Memory.put(@namespace, "counter", 2, @caps)
      Memory.put(@namespace, "counter", 3, @caps)

      assert {:ok, 3} = Memory.get(@namespace, "counter", @caps)

      rebuilt = Memory.rebuild_from_events(@namespace)
      assert rebuilt["counter"] == 3
    end

    test "rebuild_from_events handles deletes" do
      Memory.put(@namespace, "temp", "data", @caps)
      Memory.put(@namespace, "keep", "this", @caps)
      Memory.delete(@namespace, "temp", @caps)

      assert {:error, :not_found} = Memory.get(@namespace, "temp", @caps)
      assert {:ok, "this"} = Memory.get(@namespace, "keep", @caps)

      rebuilt = Memory.rebuild_from_events(@namespace)
      refute Map.has_key?(rebuilt, "temp")
      assert rebuilt["keep"] == "this"
    end

    test "rebuild_from_events scopes to namespace" do
      other_caps = [%{kind: "memory.kv", params: []}]
      Memory.put(@namespace, "key1", "val1", @caps)
      Memory.put("other_ns", "key2", "val2", other_caps)

      rebuilt = Memory.rebuild_from_events(@namespace)
      assert rebuilt["key1"] == "val1"
      refute Map.has_key?(rebuilt, "key2")

      Memory.clear("other_ns")
    end

    test "rebuild_from_events returns empty map when no events" do
      assert Memory.rebuild_from_events(@namespace) == %{}
    end
  end

  # ------------------------------------------------------------------
  # Replay memory reconstruction
  # ------------------------------------------------------------------

  describe "Replay.rebuild_memory from JSON events" do
    test "reconstructs memory from string-keyed event maps (JSON format)" do
      events = [
        %{
          "kind" => "state_change",
          "namespace" => "sessions",
          "operation" => "put",
          "key" => "user",
          "value" => "alice"
        },
        %{
          "kind" => "state_change",
          "namespace" => "sessions",
          "operation" => "put",
          "key" => "role",
          "value" => "admin"
        },
        %{"kind" => "handler", "method" => "get", "path" => "/test"},
        %{
          "kind" => "state_change",
          "namespace" => "cache",
          "operation" => "put",
          "key" => "x",
          "value" => "y"
        },
        %{
          "kind" => "state_change",
          "namespace" => "sessions",
          "operation" => "delete",
          "key" => "role"
        }
      ]

      state = Replay.rebuild_memory(events, "sessions")
      assert state == %{"user" => "alice"}
    end

    test "returns empty map for no matching namespace" do
      events = [
        %{
          "kind" => "state_change",
          "namespace" => "other",
          "operation" => "put",
          "key" => "k",
          "value" => "v"
        }
      ]

      assert Replay.rebuild_memory(events, "sessions") == %{}
    end

    test "returns empty map for no state_change events" do
      events = [
        %{"kind" => "handler", "method" => "get", "path" => "/test"},
        %{"kind" => "annotation", "key" => "step", "value" => "done"}
      ]

      assert Replay.rebuild_memory(events, "sessions") == %{}
    end
  end

  # ------------------------------------------------------------------
  # Replay new event kinds
  # ------------------------------------------------------------------

  describe "Replay.replay with unified event kinds" do
    test "replays state_change events" do
      spans = [
        %{
          "kind" => "state_change",
          "namespace" => "sessions",
          "operation" => "put",
          "key" => "user",
          "value" => "alice"
        }
      ]

      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :state_change
      assert result.namespace == "sessions"
      assert result.operation == "put"
      assert result.key == "user"
      assert result.value == "alice"
      assert result.replayed == true
    end

    test "replays user_event events" do
      spans = [
        %{"kind" => "user_event", "event" => "login", "data" => %{"user" => "bob"}}
      ]

      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :user_event
      assert result.event == "login"
      assert result.data == %{"user" => "bob"}
      assert result.replayed == true
    end

    test "replays annotation events" do
      spans = [
        %{"kind" => "annotation", "key" => "step", "value" => "analysis_complete"}
      ]

      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :annotation
      assert result.key == "step"
      assert result.value == "analysis_complete"
      assert result.replayed == true
    end

    test "replays mixed unified event stream" do
      spans = [
        %{"kind" => "handler", "method" => "post", "path" => "/login", "status" => 200},
        %{"kind" => "user_event", "event" => "login", "data" => %{}},
        %{
          "kind" => "state_change",
          "namespace" => "sessions",
          "operation" => "put",
          "key" => "user",
          "value" => "alice"
        },
        %{"kind" => "annotation", "key" => "step", "value" => "authenticated"},
        %{"kind" => "http", "method" => "get", "url" => "https://api.example.com"}
      ]

      results = Replay.replay(spans)
      assert length(results) == 5

      kinds = Enum.map(results, fn {_span, result} -> result.kind end)
      assert kinds == [:handler, :user_event, :state_change, :annotation, :http]
    end
  end
end
