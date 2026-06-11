defmodule Skein.Runtime.EventStoreTest do
  @moduledoc """
  Unit tests for the unified EventStore — the single append-only event log
  backing trace spans, user events, memory state changes, and annotations.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventStore

  setup do
    EventStore.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # append/1 and recent/1
  # ------------------------------------------------------------------

  describe "append/1" do
    test "appends an event and assigns id, timestamp, and _key" do
      EventStore.append(%{kind: :effect, method: :get})

      [event] = EventStore.recent(1)
      assert event.kind == :effect
      assert event.method == :get
      assert is_binary(event.id)
      assert is_integer(event.timestamp)
      assert is_tuple(event._key)
    end

    test "preserves all user-supplied fields" do
      EventStore.append(%{kind: :effect, method: :post, url: "/api", status: 201, custom: "data"})

      [event] = EventStore.recent(1)
      assert event.url == "/api"
      assert event.status == 201
      assert event.custom == "data"
    end

    test "generates unique ids for each event" do
      EventStore.append(%{kind: :annotation, key: "a", value: "1"})
      EventStore.append(%{kind: :annotation, key: "b", value: "2"})

      [e2, e1] = EventStore.recent(2)
      assert e1.id != e2.id
    end

    test "returns :ok" do
      assert :ok = EventStore.append(%{kind: :effect})
    end
  end

  # ------------------------------------------------------------------
  # eviction
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # log/4 — compiled event.log(name, data) with a scoped stream label
  # ------------------------------------------------------------------

  describe "log/4" do
    test "permits a stream matching the declared label and records it on the event" do
      assert :ok =
               EventStore.log("audit", "user.login", %{user: "alice"}, [
                 %{kind: "event.log", params: ["audit"]}
               ])

      [event] = EventStore.recent(1)
      assert event.kind == :user_event
      assert event.event == "user.login"
      assert event.stream == "audit"
      assert event.data == %{user: "alice"}
    end

    test "blocks a stream outside the declared label" do
      assert {:error, message} =
               EventStore.log("metrics", "user.login", %{}, [
                 %{kind: "event.log", params: ["audit"]}
               ])

      assert message =~ "metrics"
      assert message =~ "audit"
      assert EventStore.count(kind: :user_event) == 0
    end

    test "blocks a nil stream when the declaration is scoped" do
      assert {:error, _} =
               EventStore.log(nil, "user.login", %{}, [%{kind: "event.log", params: ["audit"]}])
    end

    test "unscoped declaration permits any stream" do
      assert :ok =
               EventStore.log("anything", "user.login", %{}, [%{kind: "event.log", params: []}])

      assert :ok = EventStore.log(nil, "user.login", %{}, [%{kind: "event.log", params: []}])
    end

    test "blocks when no event.log capability is declared" do
      assert {:error, message} = EventStore.log("audit", "user.login", %{}, [])
      assert message =~ "event.log"
    end
  end

  describe "size-bounded eviction" do
    test "evicts oldest events once the configured maximum is exceeded" do
      Application.put_env(:skein_runtime, :event_store_max_events, 5)
      on_exit(fn -> Application.delete_env(:skein_runtime, :event_store_max_events) end)

      for n <- 1..8 do
        EventStore.append(%{kind: :user_event, order: n})
      end

      assert EventStore.count() == 5
      orders = EventStore.all() |> Enum.map(& &1.order) |> Enum.sort()
      assert orders == [4, 5, 6, 7, 8]
    end

    test "does not evict below the maximum" do
      Application.put_env(:skein_runtime, :event_store_max_events, 100)
      on_exit(fn -> Application.delete_env(:skein_runtime, :event_store_max_events) end)

      for n <- 1..10 do
        EventStore.append(%{kind: :user_event, order: n})
      end

      assert EventStore.count() == 10
    end
  end

  # ------------------------------------------------------------------
  # recent/1
  # ------------------------------------------------------------------

  describe "recent/1" do
    test "returns events newest first" do
      EventStore.append(%{kind: :effect, order: 1})
      EventStore.append(%{kind: :effect, order: 2})
      EventStore.append(%{kind: :effect, order: 3})

      events = EventStore.recent(3)
      orders = Enum.map(events, & &1.order)
      assert orders == [3, 2, 1]
    end

    test "limits to count" do
      for i <- 1..5 do
        EventStore.append(%{kind: :effect, order: i})
      end

      assert length(EventStore.recent(3)) == 3
    end

    test "returns all if count exceeds total" do
      EventStore.append(%{kind: :effect})
      EventStore.append(%{kind: :effect})

      assert length(EventStore.recent(10)) == 2
    end

    test "returns empty list when no events" do
      assert EventStore.recent(5) == []
    end
  end

  # ------------------------------------------------------------------
  # query/1 — filter by kind
  # ------------------------------------------------------------------

  describe "query/1" do
    test "filters events by kind" do
      EventStore.append(%{kind: :effect, method: :get})
      EventStore.append(%{kind: :annotation, key: "a", value: "1"})
      EventStore.append(%{kind: :user_event, event: "login"})
      EventStore.append(%{kind: :effect, method: :post})

      effects = EventStore.query(kind: :effect)
      assert length(effects) == 2
      assert Enum.all?(effects, &(&1.kind == :effect))
    end

    test "returns newest first" do
      EventStore.append(%{kind: :annotation, key: "a", value: "1"})
      EventStore.append(%{kind: :annotation, key: "b", value: "2"})

      [e2, e1] = EventStore.query(kind: :annotation)
      assert e1.key == "a"
      assert e2.key == "b"
    end

    test "returns empty list when no events match" do
      EventStore.append(%{kind: :effect, method: :get})
      assert EventStore.query(kind: :state_change) == []
    end
  end

  # ------------------------------------------------------------------
  # query/1 — filter by multiple fields
  # ------------------------------------------------------------------

  describe "query/1 with multiple filters" do
    test "filters by kind and additional field" do
      EventStore.append(%{kind: :user_event, event: "login", data: "a"})
      EventStore.append(%{kind: :user_event, event: "logout", data: "b"})
      EventStore.append(%{kind: :user_event, event: "login", data: "c"})

      logins = EventStore.query(kind: :user_event, event: "login")
      assert length(logins) == 2
      assert Enum.all?(logins, &(&1.event == "login"))
    end

    test "filters by kind and namespace" do
      EventStore.append(%{kind: :state_change, namespace: "sessions", operation: :put})
      EventStore.append(%{kind: :state_change, namespace: "cache", operation: :put})
      EventStore.append(%{kind: :state_change, namespace: "sessions", operation: :delete})

      sessions = EventStore.query(kind: :state_change, namespace: "sessions")
      assert length(sessions) == 2
      assert Enum.all?(sessions, &(&1.namespace == "sessions"))
    end
  end

  # ------------------------------------------------------------------
  # count/0 and count/1
  # ------------------------------------------------------------------

  describe "count/0" do
    test "returns total event count" do
      assert EventStore.count() == 0

      EventStore.append(%{kind: :effect})
      EventStore.append(%{kind: :annotation, key: "a", value: "b"})
      assert EventStore.count() == 2
    end
  end

  describe "count/1" do
    test "returns count filtered by kind" do
      EventStore.append(%{kind: :effect})
      EventStore.append(%{kind: :annotation, key: "a", value: "b"})
      EventStore.append(%{kind: :effect})

      assert EventStore.count(kind: :effect) == 2
      assert EventStore.count(kind: :annotation) == 1
      assert EventStore.count(kind: :user_event) == 0
    end
  end

  # ------------------------------------------------------------------
  # all/0
  # ------------------------------------------------------------------

  describe "all/0" do
    test "returns all events newest first" do
      EventStore.append(%{kind: :effect, order: 1})
      EventStore.append(%{kind: :annotation, key: "a", value: "b", order: 2})
      EventStore.append(%{kind: :user_event, event: "x", order: 3})

      events = EventStore.all()
      assert length(events) == 3
      orders = Enum.map(events, & &1.order)
      assert orders == [3, 2, 1]
    end
  end

  # ------------------------------------------------------------------
  # clear/0
  # ------------------------------------------------------------------

  describe "clear/0" do
    test "removes all events" do
      EventStore.append(%{kind: :effect})
      EventStore.append(%{kind: :annotation, key: "a", value: "b"})
      assert EventStore.count() == 2

      EventStore.clear()
      assert EventStore.count() == 0
      assert EventStore.recent(10) == []
    end
  end

  # ------------------------------------------------------------------
  # since/1 — time-based filtering
  # ------------------------------------------------------------------

  describe "since/1" do
    test "returns events since a given timestamp" do
      EventStore.append(%{kind: :effect, order: 1})
      Process.sleep(1)

      # Get the timestamp of the first event to use as boundary
      [first] = EventStore.recent(1)
      cutoff = first.timestamp

      Process.sleep(1)
      EventStore.append(%{kind: :effect, order: 2})
      EventStore.append(%{kind: :effect, order: 3})

      events = EventStore.since(cutoff)
      # Should include events strictly after the cutoff
      assert length(events) >= 2
      assert Enum.all?(events, &(&1.timestamp >= cutoff))
    end
  end

  # ------------------------------------------------------------------
  # snapshot/1 — export for golden tests
  # ------------------------------------------------------------------

  describe "snapshot/0" do
    test "returns all events oldest first (chronological order)" do
      EventStore.append(%{kind: :effect, order: 1})
      EventStore.append(%{kind: :annotation, key: "a", value: "b", order: 2})
      EventStore.append(%{kind: :effect, order: 3})

      snapshot = EventStore.snapshot()
      orders = Enum.map(snapshot, & &1.order)
      assert orders == [1, 2, 3]
    end

    test "snapshot is JSON-serializable" do
      EventStore.append(%{kind: :effect, method: :get, url: "/test"})
      EventStore.append(%{kind: :user_event, event: "login", data: %{user: "alice"}})

      snapshot = EventStore.snapshot()
      assert {:ok, json} = Jason.encode(snapshot)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_list(decoded)
      assert length(decoded) == 2
    end
  end
end
