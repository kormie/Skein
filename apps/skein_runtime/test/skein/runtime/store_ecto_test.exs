defmodule Skein.Runtime.StoreEctoTest do
  @moduledoc """
  Tests for the Ecto-backed store backend.

  These tests start a real SQLite database, run migrations, and perform
  CRUD operations through the Skein store interface backed by Ecto.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Store
  alias Skein.Runtime.StoreEcto
  alias Skein.Runtime.EctoSchema
  alias Skein.Runtime.MigrationGen
  alias Skein.Runtime.Trace

  @caps [%{kind: "store.table", params: ["ecto_users"]}]

  @user_fields [
    %{name: "id", type: "Uuid", annotations: ["primary"]},
    %{name: "email", type: "String", annotations: ["unique"]},
    %{name: "name", type: "String", annotations: []}
  ]

  setup_all do
    # Create a temp SQLite database
    db_path =
      Path.join(System.tmp_dir!(), "skein_store_ecto_test_#{:rand.uniform(100_000)}.db")

    # Stop any existing repo
    try do
      GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
    catch
      :exit, _ -> :ok
    end

    # Start the repo
    {:ok, _pid} =
      Skein.Runtime.Repo.start_link(
        database: db_path,
        pool_size: 1
      )

    # Run migration to create the table
    {:ok, migration_mod} = MigrationGen.build_migration("ecto_users", @user_fields)
    :ok = MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)

    # Build the schema module
    {:ok, schema_mod} = EctoSchema.build_schema("ecto_users", @user_fields)

    # Register the schema with the Ecto store backend
    StoreEcto.register_schema("ecto_users", schema_mod)

    on_exit(fn ->
      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm(db_path)
    end)

    {:ok, schema_mod: schema_mod, db_path: db_path}
  end

  setup do
    # Clear table between tests
    StoreEcto.clear("ecto_users")
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # store.put (Ecto)
  # ------------------------------------------------------------------

  describe "put/3" do
    test "inserts a new record" do
      record = %{id: "u1", email: "alice@example.com", name: "Alice"}
      assert {:ok, result} = StoreEcto.put("ecto_users", record, @caps)
      assert result.id == "u1"
      assert result.email == "alice@example.com"
      assert result.name == "Alice"
    end

    test "upserts an existing record" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "alice@test.com", name: "Alice"}, @caps)

      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "alicia@test.com", name: "Alicia"}, @caps)

      {:ok, record} = StoreEcto.get("ecto_users", "u1", @caps)
      assert record.name == "Alicia"
      assert record.email == "alicia@test.com"
    end

    test "returns capability error when table not declared" do
      result = StoreEcto.put("orders", %{id: "o1"}, @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.get (Ecto)
  # ------------------------------------------------------------------

  describe "get/3" do
    test "retrieves an existing record by id" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "alice@test.com", name: "Alice"}, @caps)

      assert {:ok, record} = StoreEcto.get("ecto_users", "u1", @caps)
      assert record.name == "Alice"
      assert record.email == "alice@test.com"
    end

    test "returns not_found for missing id" do
      assert {:error, :not_found} = StoreEcto.get("ecto_users", "nonexistent", @caps)
    end

    test "returns capability error when table not declared" do
      assert {:error, {:denied, msg}} = StoreEcto.get("orders", "o1", @caps)
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.delete (Ecto)
  # ------------------------------------------------------------------

  describe "delete/3" do
    test "removes an existing record" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      assert {:ok, "u1"} = StoreEcto.delete("ecto_users", "u1", @caps)
      assert {:error, :not_found} = StoreEcto.get("ecto_users", "u1", @caps)
    end

    test "deleting a non-existent id succeeds silently" do
      assert {:ok, "u999"} = StoreEcto.delete("ecto_users", "u999", @caps)
    end

    test "returns capability error when table not declared" do
      assert {:error, {:denied, msg}} = StoreEcto.delete("orders", "o1", @caps)
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.query (Ecto)
  # ------------------------------------------------------------------

  describe "query/3" do
    test "returns records matching a single filter" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      {:ok, _} = StoreEcto.put("ecto_users", %{id: "u2", email: "b@test.com", name: "Bob"}, @caps)

      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u3", email: "c@test.com", name: "Alice"}, @caps)

      {:ok, results} = StoreEcto.query("ecto_users", %{name: "Alice"}, @caps)
      assert is_list(results)
      assert length(results) == 2

      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == ["u1", "u3"]
    end

    test "returns records matching multiple filters" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u2", email: "b@test.com", name: "Alice"}, @caps)

      {:ok, results} = StoreEcto.query("ecto_users", %{name: "Alice", email: "a@test.com"}, @caps)
      assert length(results) == 1
      assert hd(results).id == "u1"
    end

    test "returns empty list when no records match" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      {:ok, results} = StoreEcto.query("ecto_users", %{name: "Nobody"}, @caps)
      assert results == []
    end

    test "returns all records with empty filters" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      {:ok, _} = StoreEcto.put("ecto_users", %{id: "u2", email: "b@test.com", name: "Bob"}, @caps)

      {:ok, results} = StoreEcto.query("ecto_users", %{}, @caps)
      assert length(results) == 2
    end

    test "returns capability error when table not declared" do
      result = StoreEcto.query("orders", %{}, @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end

    test "rejects filter keys that are not schema fields" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      assert {:error, {:failed, msg}} =
               StoreEcto.query("ecto_users", %{"not_a_column" => "x"}, @caps)

      assert msg =~ "Unknown filter field"
      assert msg =~ "not_a_column"
    end

    test "accepts string filter keys for declared fields" do
      {:ok, _} =
        StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      {:ok, results} = StoreEcto.query("ecto_users", %{"name" => "Alice"}, @caps)
      assert length(results) == 1
    end
  end

  # ------------------------------------------------------------------
  # Trace integration
  # ------------------------------------------------------------------

  describe "tracing" do
    test "put records a trace span" do
      StoreEcto.put("ecto_users", %{id: "u1", email: "a@test.com", name: "Alice"}, @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :put
      assert span.table == "ecto_users"
      assert is_integer(span.duration_us)
      assert span.outcome == :ok
    end

    test "get records a trace span" do
      StoreEcto.get("ecto_users", "u1", @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.method == :get
    end

    test "query records a trace span" do
      StoreEcto.query("ecto_users", %{}, @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.method == :query
    end
  end
end
