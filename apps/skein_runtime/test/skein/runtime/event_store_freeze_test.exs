defmodule Skein.Runtime.EventStoreFreezeTest do
  # Persistence is a global singleton (GenServer + Repo); never async.
  use ExUnit.Case, async: false

  @moduledoc """
  Wave F freeze gate (#332) for the EventStore persisted event shapes.

  This promotes the persisted-and-reloaded shape contract from the
  `Persistence` moduledoc (Pre-stable until now) to frozen vectors: for a
  representative event of every persisted class, the exact reloaded map —
  including which keys come back as atoms vs strings and which values are
  re-atomized — is pinned literally below. `id` and `timestamp` are
  append-time values and are normalized before comparison.

  Post-freeze rules (`docs/STABILITY.md`): shapes only gain fields within
  1.x; existing fields are never renamed or repurposed; a key moving
  between the atom-keyed and string-keyed sets is a shape change and
  therefore breaking.
  """

  alias Skein.Runtime.EventStore
  alias Skein.Runtime.EventStore.Persistence

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "skein_event_freeze_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    db_path = Path.join(tmp_dir, "events.db")

    Persistence.disable()
    EventStore.clear()

    on_exit(fn ->
      Persistence.disable()
      EventStore.clear()
      stop_repo()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, db_path: db_path}
  end

  defp stop_repo do
    try do
      GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
    catch
      :exit, _ -> :ok
    end
  end

  # One representative appended event per persisted class, with the exact
  # reloaded map it must produce (after id/timestamp normalization).
  @vectors [
    {:user_event,
     %{
       kind: :user_event,
       event: "player_joined",
       stream: "audit",
       data: %{"name" => "alice", "hp" => 100},
       wall_time: 1_760_000_000_000,
       url: "https://example.com"
     },
     %{
       # unknown keys come back string-keyed; the rest (the backend's
       # known metadata set) come back atom-keyed
       "url" => "https://example.com",
       kind: :user_event,
       event: "player_joined",
       stream: "audit",
       data: %{"name" => "alice", "hp" => 100},
       wall_time: 1_760_000_000_000
     }},
    {:effect_span,
     %{
       kind: :llm,
       method: :chat,
       model: "claude-opus-4-8",
       duration_us: 1234,
       outcome: :ok
     },
     %{
       # model is not in the known metadata set — string key, string value
       "model" => "claude-opus-4-8",
       kind: :llm,
       method: :chat,
       duration_us: 1234,
       outcome: :ok
     }},
    {:state_change,
     %{
       kind: :state_change,
       operation: :put,
       namespace: "sessions",
       key: "k1",
       value: "v1"
     },
     %{
       kind: :state_change,
       operation: :put,
       namespace: "sessions",
       key: "k1",
       value: "v1"
     }},
    {:annotation, %{kind: :annotation, key: "label", value: "checkout"},
     %{kind: :annotation, key: "label", value: "checkout"}},
    {:supervisor, %{kind: :supervisor, event: "child_started", data: %{"target" => "Worker"}},
     %{kind: :supervisor, event: "child_started", data: %{"target" => "Worker"}}},
    {:nil_and_bool,
     %{kind: :user_event, event: "toggled", stream: "audit", data: nil, enabled: true},
     %{
       # nil and booleans are preserved as JSON null/true, not stringified
       "enabled" => true,
       kind: :user_event,
       event: "toggled",
       stream: "audit",
       data: nil
     }}
  ]

  test "persisted-and-reloaded shapes match the frozen vectors", %{db_path: db_path} do
    assert :ok = Persistence.enable(db_path)

    appended =
      for {name, event, _expected} <- @vectors do
        :ok = EventStore.append(event)
        {name, List.first(EventStore.recent(1))}
      end

    assert Persistence.flush() == :ok

    # Simulated restart: wipe ETS, re-enable from the same database.
    EventStore.clear()
    Persistence.disable()
    assert :ok = Persistence.enable(db_path)

    reloaded = EventStore.recent(length(@vectors))

    for {name, _event, expected} <- @vectors do
      {^name, original} = List.keyfind(appended, name, 0)

      found =
        Enum.find(reloaded, fn candidate ->
          Map.get(candidate, :id) == Map.get(original, :id)
        end)

      assert found, "#{name}: persisted event not reloaded"

      # id/timestamp are append-time values — verified preserved, then
      # normalized out of the shape comparison along with :_key (the
      # internal ETS ordering key, never persisted).
      assert Map.get(found, :id) == Map.get(original, :id)
      assert Map.get(found, :timestamp) == Map.get(original, :timestamp)

      normalized = Map.drop(found, [:id, :timestamp, :_key])

      assert normalized == expected,
             "#{name}: the persisted-and-reloaded shape drifted from the frozen " <>
               "vector — persisted shapes only gain fields within a major " <>
               "(docs/STABILITY.md, frozen at the Wave F gate #332)"
    end
  end
end
