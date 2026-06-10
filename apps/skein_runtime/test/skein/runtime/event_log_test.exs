defmodule Skein.Runtime.EventLogTest do
  @moduledoc """
  Back-compat coverage for the deprecated `Skein.Runtime.EventLog` facade.

  EventLog delegates everything to `Skein.Runtime.EventStore`; this suite is
  retained intentionally to guarantee the deprecated API keeps working until
  it is removed. New tests belong in `event_store_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventLog

  setup do
    # Reset before each test, not just after: the EventStore is a shared
    # ETS table, and any traced operation elsewhere in the suite appends
    # to it — assertions like count() == 0 must not depend on seed order.
    EventLog.reset_all()
    on_exit(fn -> EventLog.reset_all() end)
  end

  describe "log/3" do
    test "logs an event and returns :ok" do
      assert :ok =
               EventLog.log("user.login", %{user_id: "u1"}, [%{kind: "event.log", params: []}])
    end

    test "logged event is retrievable" do
      EventLog.log("user.login", %{user_id: "u1"}, [%{kind: "event.log", params: []}])

      events = EventLog.all()
      assert length(events) == 1
      event = hd(events)
      assert event.event == "user.login"
      assert event.data == %{user_id: "u1"}
      assert is_integer(event.timestamp)
      assert is_binary(event.id)
    end

    test "multiple events are stored" do
      EventLog.log("user.login", %{user_id: "u1"}, [%{kind: "event.log", params: []}])
      EventLog.log("user.logout", %{user_id: "u1"}, [%{kind: "event.log", params: []}])
      EventLog.log("user.login", %{user_id: "u2"}, [%{kind: "event.log", params: []}])

      assert EventLog.count() == 3
    end

    test "events with string data" do
      EventLog.log("system.start", "booted", [%{kind: "event.log", params: []}])

      events = EventLog.all()
      assert length(events) == 1
      assert hd(events).data == "booted"
    end
  end

  describe "all/0" do
    test "returns empty list when no events" do
      assert EventLog.all() == []
    end

    test "returns events in reverse chronological order" do
      EventLog.log("first", %{}, [%{kind: "event.log", params: []}])
      Process.sleep(1)
      EventLog.log("second", %{}, [%{kind: "event.log", params: []}])
      Process.sleep(1)
      EventLog.log("third", %{}, [%{kind: "event.log", params: []}])

      events = EventLog.all()
      assert length(events) == 3
      assert [third, second, first] = events
      assert third.event == "third"
      assert second.event == "second"
      assert first.event == "first"
    end
  end

  describe "query/1" do
    test "filters events by name" do
      EventLog.log("user.login", %{user: "a"}, [%{kind: "event.log", params: []}])
      EventLog.log("user.logout", %{user: "a"}, [%{kind: "event.log", params: []}])
      EventLog.log("user.login", %{user: "b"}, [%{kind: "event.log", params: []}])

      logins = EventLog.query("user.login")
      assert length(logins) == 2
      assert Enum.all?(logins, &(&1.event == "user.login"))
    end

    test "returns empty list for unknown event name" do
      EventLog.log("user.login", %{}, [%{kind: "event.log", params: []}])
      assert EventLog.query("nonexistent") == []
    end
  end

  describe "count/0" do
    test "returns 0 when no events" do
      assert EventLog.count() == 0
    end

    test "returns correct count" do
      EventLog.log("a", %{}, [%{kind: "event.log", params: []}])
      EventLog.log("b", %{}, [%{kind: "event.log", params: []}])
      assert EventLog.count() == 2
    end
  end

  describe "reset_all/0" do
    test "clears all events" do
      EventLog.log("a", %{}, [%{kind: "event.log", params: []}])
      EventLog.log("b", %{}, [%{kind: "event.log", params: []}])
      assert EventLog.count() == 2

      EventLog.reset_all()
      assert EventLog.count() == 0
    end
  end
end
