defmodule Skein.Runtime.EventStorePropertyTest do
  @moduledoc """
  Property-based tests for the unified EventStore.

  Tests ordering invariants, metadata preservation, query correctness,
  and count consistency across varied event types and sequences.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.EventStore

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp kind_gen do
    StreamData.member_of([:effect, :annotation, :user_event, :state_change])
  end

  defp effect_event_gen do
    gen all(
          method <- StreamData.member_of([:get, :post, :put, :delete]),
          duration <- StreamData.integer(0..100_000),
          outcome <- StreamData.member_of([:ok, :error])
        ) do
      %{kind: :effect, method: method, duration_us: duration, outcome: outcome}
    end
  end

  defp annotation_event_gen do
    gen all(
          key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          value <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
        ) do
      %{kind: :annotation, key: key, value: value}
    end
  end

  defp user_event_gen do
    gen all(
          event <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          data <- StreamData.string(:alphanumeric, min_length: 0, max_length: 50)
        ) do
      %{kind: :user_event, event: event, data: data}
    end
  end

  defp state_change_event_gen do
    gen all(
          namespace <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
          operation <- StreamData.member_of([:put, :delete]),
          key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
        ) do
      %{kind: :state_change, namespace: namespace, operation: operation, key: key}
    end
  end

  defp any_event_gen do
    StreamData.one_of([
      effect_event_gen(),
      annotation_event_gen(),
      user_event_gen(),
      state_change_event_gen()
    ])
  end

  setup do
    EventStore.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "append preserves all user-supplied fields" do
    check all(event <- any_event_gen()) do
      EventStore.clear()
      EventStore.append(event)
      [recorded] = EventStore.recent(1)

      for {k, v} <- event do
        assert Map.get(recorded, k) == v,
               "field #{inspect(k)} expected #{inspect(v)}, got #{inspect(Map.get(recorded, k))}"
      end
    end
  end

  property "every appended event gets a unique id" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 2, max_length: 20)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      all_events = EventStore.all()
      ids = Enum.map(all_events, & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  property "recent returns at most count events" do
    check all(
            events <- StreamData.list_of(any_event_gen(), min_length: 1, max_length: 20),
            count <- StreamData.integer(1..25)
          ) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      result = EventStore.recent(count)
      assert length(result) == min(length(events), count)
    end
  end

  property "recent returns events in reverse chronological order" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 2, max_length: 15)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      result = EventStore.recent(length(events))
      timestamps = Enum.map(result, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :desc)
    end
  end

  property "query by kind returns only events of that kind" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 1, max_length: 20)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      for kind <- [:effect, :annotation, :user_event, :state_change] do
        queried = EventStore.query(kind: kind)
        expected_count = Enum.count(events, &(&1.kind == kind))
        assert length(queried) == expected_count
        assert Enum.all?(queried, &(&1.kind == kind))
      end
    end
  end

  property "count matches length of all" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 0, max_length: 15)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      assert EventStore.count() == length(events)
    end
  end

  property "count by kind matches query by kind length" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 1, max_length: 15)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      for kind <- [:effect, :annotation, :user_event, :state_change] do
        assert EventStore.count(kind: kind) == length(EventStore.query(kind: kind))
      end
    end
  end

  property "clear removes all events regardless of kind" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 1, max_length: 15)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      EventStore.clear()
      assert EventStore.count() == 0
      assert EventStore.all() == []
    end
  end

  property "snapshot returns events in chronological (oldest first) order" do
    check all(events <- StreamData.list_of(any_event_gen(), min_length: 2, max_length: 15)) do
      EventStore.clear()

      for event <- events do
        EventStore.append(event)
      end

      snapshot = EventStore.snapshot()
      timestamps = Enum.map(snapshot, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :asc)
    end
  end
end
