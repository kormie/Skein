defmodule Skein.Runtime.EventLogPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.EventLog

  setup do
    on_exit(fn -> EventLog.reset_all() end)
  end

  property "logging N events results in count() == N" do
    check all(count <- integer(1..20)) do
      EventLog.reset_all()

      for i <- 1..count do
        EventLog.log("event.#{i}", %{i: i}, [])
      end

      assert EventLog.count() == count
    end
  end

  property "every logged event is retrievable" do
    check all(event_name <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      EventLog.reset_all()
      event_name = "evt.#{event_name}"

      EventLog.log(event_name, %{test: true}, [])

      events = EventLog.query(event_name)
      assert length(events) == 1
      assert hd(events).event == event_name
    end
  end

  property "log always returns :ok" do
    check all(
            name <- string(:alphanumeric, min_length: 1, max_length: 20),
            data <- one_of([constant(%{}), constant("string_data"), constant(42)])
          ) do
      name = "evt.#{name}"
      assert :ok = EventLog.log(name, data, [])
    end
  end

  property "all events have unique ids" do
    check all(count <- integer(2..15)) do
      EventLog.reset_all()

      for i <- 1..count do
        EventLog.log("event", %{i: i}, [])
      end

      events = EventLog.all()
      ids = Enum.map(events, & &1.id)
      assert length(Enum.uniq(ids)) == count
    end
  end

  property "events are ordered by timestamp descending in all()" do
    check all(count <- integer(2..10)) do
      EventLog.reset_all()

      for i <- 1..count do
        EventLog.log("event.#{i}", %{}, [])
        # Small sleep to ensure distinct timestamps
        Process.sleep(1)
      end

      events = EventLog.all()
      timestamps = Enum.map(events, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :desc)
    end
  end
end
