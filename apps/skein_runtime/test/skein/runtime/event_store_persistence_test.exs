defmodule Skein.Runtime.EventStore.PersistenceTest do
  @moduledoc """
  Restart-durability tests for the opt-in EventStore SQLite persistence
  (`Skein.Runtime.EventStore.Persistence`, issue #299 / roadmap C6).

  Events flow through the ORDINARY `EventStore.append/1` / `EventStore.log/4`
  path; persistence is an async side channel enabled by `Persistence.enable/1`
  (which `skein run` calls by default). A restart is simulated by wiping the
  ETS log (`EventStore.clear/0`) and re-enabling persistence against the same
  database file.

  ## Pinned persisted-and-reloaded event shape

  Persisted events round-trip through JSON (`SqliteBackend`), so a reloaded
  event is NOT bit-identical to the original:

  - keys in the backend's known metadata set (`id`, `kind`, `timestamp`,
    `event`, `stream`, `data`, `method`, `operation`, `namespace`, `key`,
    `value`, `order`, `outcome`, `duration_us`, `wall_time`) come back as
    atom keys; all other keys come back as STRING keys (e.g. `"url"`)
  - `kind`/`method`/`operation`/`outcome` values are re-atomized; all other
    atom values come back as strings (`nil`/booleans are preserved as JSON
    null/booleans)
  - nested map data keeps its JSON shape: string keys throughout
  - `id` and `timestamp` are the original values assigned at append time
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventStore
  alias Skein.Runtime.EventStore.Persistence
  alias Skein.Runtime.EventStore.SqliteBackend

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "skein_event_persistence_#{System.unique_integer([:positive])}"
      )

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

  describe "disabled by default" do
    test "ordinary append never touches the database", %{db_path: db_path} do
      :ok = EventStore.append(%{kind: :user_event, event: "login", data: "alice"})

      refute Persistence.enabled?()
      assert Persistence.flush() == :ok
      refute File.exists?(db_path)
    end
  end

  describe "enable/1 + ordinary append path" do
    test "events survive a simulated restart (ETS wipe + fresh enable)", %{db_path: db_path} do
      assert :ok = Persistence.enable(db_path)
      assert Persistence.enabled?()

      :ok =
        EventStore.append(%{
          kind: :user_event,
          event: "login",
          stream: "audit",
          data: %{"user" => "alice"}
        })

      :ok = EventStore.append(%{kind: :effect, method: :get, url: "/api"})

      assert :ok = Persistence.flush()
      assert File.exists?(db_path)

      # Simulate restart: ETS log wiped, persistence re-enabled fresh.
      Persistence.disable()
      EventStore.clear()
      assert EventStore.count() == 0

      assert :ok = Persistence.enable(db_path)
      assert EventStore.count() == 2

      # Round-tripped user event: known keys re-atomized, kind re-atomized,
      # data keeps its JSON string keys.
      [user_event] = EventStore.query(kind: :user_event)
      assert user_event.kind == :user_event
      assert user_event.event == "login"
      assert user_event.stream == "audit"
      assert user_event.data == %{"user" => "alice"}
      assert is_binary(user_event.id)
      assert is_integer(user_event.timestamp)

      # Round-tripped effect: method value re-atomized; unknown keys
      # ("url") come back as STRING keys — pinned honestly.
      [effect] = EventStore.query(kind: :effect)
      assert effect.method == :get
      refute Map.has_key?(effect, :url)
      assert effect["url"] == "/api"
    end

    test "event.log path is persisted with its stream label", %{db_path: db_path} do
      assert :ok = Persistence.enable(db_path)

      capabilities = [%{kind: "event.log", params: ["audit"]}]

      assert {:ok, "user.signup"} =
               EventStore.log("audit", "user.signup", %{"plan" => "pro"}, capabilities)

      assert :ok = Persistence.flush()

      Persistence.disable()
      EventStore.clear()
      assert :ok = Persistence.enable(db_path)

      [event] = EventStore.query(kind: :user_event)
      assert event.event == "user.signup"
      assert event.stream == "audit"
      assert event.data == %{"plan" => "pro"}
      assert is_integer(event.wall_time)
    end

    test "reloaded events keep their original id and timestamp", %{db_path: db_path} do
      assert :ok = Persistence.enable(db_path)

      :ok = EventStore.append(%{kind: :user_event, event: "once", data: nil})
      assert :ok = Persistence.flush()

      [original] = EventStore.query(kind: :user_event)

      Persistence.disable()
      EventStore.clear()
      assert :ok = Persistence.enable(db_path)

      [reloaded] = EventStore.query(kind: :user_event)
      assert reloaded.id == original.id
      assert reloaded.timestamp == original.timestamp
      assert reloaded.data == nil
    end

    test "enable is idempotent — re-enabling does not duplicate events", %{db_path: db_path} do
      assert :ok = Persistence.enable(db_path)

      :ok = EventStore.append(%{kind: :user_event, event: "one", data: 1})
      :ok = EventStore.append(%{kind: :user_event, event: "two", data: 2})
      assert :ok = Persistence.flush()

      # Enabling again while the ETS log is still populated must not
      # duplicate: the reload is deduplicated by event id.
      assert :ok = Persistence.enable(db_path)
      assert EventStore.count() == 2

      Persistence.disable()
      assert :ok = Persistence.enable(db_path)
      assert EventStore.count() == 2
    end
  end

  describe "eviction vs. durability" do
    test "ETS stays bounded while SQLite keeps everything", %{db_path: db_path} do
      original = Application.get_env(:skein_runtime, :event_store_max_events)
      Application.put_env(:skein_runtime, :event_store_max_events, 5)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:skein_runtime, :event_store_max_events)
          value -> Application.put_env(:skein_runtime, :event_store_max_events, value)
        end
      end)

      assert :ok = Persistence.enable(db_path)

      for i <- 1..12 do
        :ok = EventStore.append(%{kind: :user_event, event: "e#{i}", data: i})
      end

      assert :ok = Persistence.flush()

      # ETS is bounded to the configured maximum...
      assert EventStore.count() == 5

      # ...while SQLite retained the full history.
      assert length(SqliteBackend.load_all()) == 12
    end
  end
end
