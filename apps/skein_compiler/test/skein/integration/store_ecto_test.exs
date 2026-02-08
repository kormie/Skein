defmodule Skein.Integration.StoreEctoTest do
  @moduledoc """
  Integration test: compile a Skein module with `store.table` capability,
  set up SQLite via Ecto, and perform real CRUD operations.

  This is the Phase 8b acceptance test — proving the full pipeline works:
  1. Skein source → compilation → BEAM module
  2. Extract type/field metadata from compiled module
  3. Generate Ecto schema + migration dynamically
  4. Run migration against SQLite
  5. Execute store operations (get, put, query, delete) via Ecto
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler
  alias Skein.Runtime.EctoSchema
  alias Skein.Runtime.MigrationGen
  alias Skein.Runtime.StoreEcto
  alias Skein.Runtime.Trace

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  setup_all do
    db_path =
      Path.join(System.tmp_dir!(), "skein_integration_store_#{:rand.uniform(100_000)}.db")

    # Stop any existing repo
    try do
      GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
    catch
      :exit, _ -> :ok
    end

    # Start the Ecto repo
    {:ok, _pid} =
      Skein.Runtime.Repo.start_link(
        database: db_path,
        pool_size: 1
      )

    on_exit(fn ->
      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm(db_path)
    end)

    {:ok, db_path: db_path}
  end

  setup do
    Trace.clear()
    :ok
  end

  describe "end-to-end store operations via Ecto" do
    test "compile module, migrate, and perform CRUD against SQLite" do
      # 1. Compile a Skein module with store.table capability
      mod =
        compile!("""
        module UserService {
          capability store.table("integration_users")

          type User {
            id: Uuid @primary
            email: String @unique
            name: String
          }

          fn get_user(id: String) -> String {
            id
          }
        }
        """)

      # 2. Verify the module compiled and has capabilities
      caps = mod.__capabilities__()
      assert Enum.any?(caps, fn cap -> cap.kind == "store.table" end)

      store_cap = Enum.find(caps, fn cap -> cap.kind == "store.table" end)
      assert "integration_users" in store_cap.params

      # 3. Set up the database — generate schema and migration from type info
      user_fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, migration_mod} = MigrationGen.build_migration("integration_users", user_fields)
      :ok = MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)

      {:ok, schema_mod} = EctoSchema.build_schema("integration_users", user_fields)
      StoreEcto.register_schema("integration_users", schema_mod)

      # 4. Perform CRUD operations against the real SQLite database
      caps_list = [%{kind: "store.table", params: ["integration_users"]}]

      # PUT — insert a new record
      {:ok, inserted} =
        StoreEcto.put(
          "integration_users",
          %{id: "user-001", email: "alice@example.com", name: "Alice"},
          caps_list
        )

      assert inserted.id == "user-001"
      assert inserted.email == "alice@example.com"
      assert inserted.name == "Alice"

      # GET — retrieve by primary key
      {:ok, fetched} = StoreEcto.get("integration_users", "user-001", caps_list)
      assert fetched.id == "user-001"
      assert fetched.name == "Alice"

      # PUT — upsert (update existing)
      {:ok, updated} =
        StoreEcto.put(
          "integration_users",
          %{id: "user-001", email: "alicia@example.com", name: "Alicia"},
          caps_list
        )

      assert updated.name == "Alicia"

      {:ok, refetched} = StoreEcto.get("integration_users", "user-001", caps_list)
      assert refetched.name == "Alicia"
      assert refetched.email == "alicia@example.com"

      # PUT — insert a second record
      {:ok, _} =
        StoreEcto.put(
          "integration_users",
          %{id: "user-002", email: "bob@example.com", name: "Bob"},
          caps_list
        )

      # QUERY — find by name
      results = StoreEcto.query("integration_users", %{name: "Alicia"}, caps_list)
      assert length(results) == 1
      assert hd(results).email == "alicia@example.com"

      # QUERY — find all
      all_results = StoreEcto.query("integration_users", %{}, caps_list)
      assert length(all_results) == 2

      # DELETE — remove a record
      {:ok, "user-001"} = StoreEcto.delete("integration_users", "user-001", caps_list)
      assert {:error, "not_found"} = StoreEcto.get("integration_users", "user-001", caps_list)

      # GET — remaining record still exists
      {:ok, bob} = StoreEcto.get("integration_users", "user-002", caps_list)
      assert bob.name == "Bob"

      # Verify traces were recorded
      spans = Trace.recent_spans(20)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) > 0

      methods = Enum.map(store_spans, & &1.method) |> Enum.uniq() |> Enum.sort()
      assert :delete in methods
      assert :get in methods
      assert :put in methods
      assert :query in methods
    end

    test "capability enforcement blocks unauthorized tables" do
      caps_list = [%{kind: "store.table", params: ["integration_users"]}]

      result = StoreEcto.get("unauthorized_table", "id", caps_list)
      assert {:error, msg} = result
      assert msg =~ "not declared"
    end

    test "multiple store.table capabilities work" do
      mod =
        compile!("""
        module MultiStore {
          capability store.table("products")
          capability store.table("orders")

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      store_caps = Enum.filter(caps, fn cap -> cap.kind == "store.table" end)
      table_names = Enum.flat_map(store_caps, fn cap -> cap.params end)

      assert "products" in table_names
      assert "orders" in table_names
    end
  end
end
