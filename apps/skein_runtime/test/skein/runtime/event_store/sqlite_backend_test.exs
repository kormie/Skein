defmodule Skein.Runtime.EventStore.SqliteBackendTest do
  @moduledoc """
  Tests for the SQLite-backed persistent EventStore.

  Verifies events survive process restarts, ETS acts as read cache,
  and the API is identical to the ETS-only EventStore.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.EventStore
  alias Skein.Runtime.EventStore.SqliteBackend

  @db_path Path.join(System.tmp_dir!(), "skein_event_store_test_#{:rand.uniform(100_000)}.db")

  setup do
    # Stop any existing repo
    try do
      GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
    catch
      :exit, _ -> :ok
    end

    {:ok, _pid} =
      Skein.Runtime.Repo.start_link(
        database: @db_path,
        pool_size: 1
      )

    # Run migration
    SqliteBackend.migrate()

    # Clear both ETS and SQLite
    EventStore.clear()
    SqliteBackend.clear()

    on_exit(fn ->
      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm(@db_path)
    end)

    :ok
  end

  describe "persistence" do
    test "events survive ETS clear when persisted to SQLite" do
      SqliteBackend.append(%{kind: :user_event, event: "login", data: "alice"})
      SqliteBackend.append(%{kind: :effect, method: :get, url: "/api"})

      # Clear ETS (simulating restart)
      EventStore.clear()
      assert EventStore.count() == 0

      # Load from SQLite back into ETS
      loaded = SqliteBackend.load_all()
      assert length(loaded) == 2
    end

    test "appended events are queryable from SQLite" do
      SqliteBackend.append(%{kind: :user_event, event: "signup", data: %{name: "bob"}})

      events = SqliteBackend.query(kind: :user_event)
      assert length(events) == 1
      assert hd(events).event == "signup"
    end

    test "clear removes all SQLite events" do
      SqliteBackend.append(%{kind: :effect, method: :post})
      SqliteBackend.append(%{kind: :annotation, key: "a", value: "b"})

      SqliteBackend.clear()
      assert SqliteBackend.load_all() == []
    end
  end

  describe "round-trip fidelity" do
    test "preserves event kind as atom" do
      SqliteBackend.append(%{kind: :state_change, namespace: "sess", operation: :put, key: "k"})

      [event] = SqliteBackend.load_all()
      assert event.kind == :state_change
    end

    test "preserves complex data via JSON serialization" do
      SqliteBackend.append(%{kind: :user_event, event: "order", data: %{"items" => [1, 2, 3]}})

      [event] = SqliteBackend.load_all()
      assert event.data == %{"items" => [1, 2, 3]}
    end

    test "preserves timestamp ordering" do
      SqliteBackend.append(%{kind: :effect, order: 1})
      Process.sleep(1)
      SqliteBackend.append(%{kind: :effect, order: 2})

      events = SqliteBackend.load_all()
      orders = Enum.map(events, & &1[:order] || &1["order"])
      assert orders == [1, 2]
    end
  end

  describe "load_into_ets/0" do
    test "populates ETS cache from SQLite on startup" do
      SqliteBackend.append(%{kind: :user_event, event: "test1", data: "a"})
      SqliteBackend.append(%{kind: :effect, method: :get})

      # Clear ETS
      EventStore.clear()
      assert EventStore.count() == 0

      # Load into ETS
      SqliteBackend.load_into_ets()
      assert EventStore.count() == 2
    end
  end
end
