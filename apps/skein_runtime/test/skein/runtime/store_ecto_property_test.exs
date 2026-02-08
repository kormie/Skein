defmodule Skein.Runtime.StoreEctoPropertyTest do
  @moduledoc """
  Property-based tests for the Ecto-backed store backend.

  Mirrors the ETS store property tests but runs against a real SQLite database
  to verify behavioral equivalence between the two backends.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.StoreEcto
  alias Skein.Runtime.EctoSchema
  alias Skein.Runtime.MigrationGen

  @caps [%{kind: "store.table", params: ["ecto_prop_test"]}]

  @prop_fields [
    %{name: "id", type: "String", annotations: ["primary"]},
    %{name: "name", type: "String", annotations: []},
    %{name: "age", type: "Int", annotations: []}
  ]

  setup_all do
    db_path =
      Path.join(System.tmp_dir!(), "skein_store_ecto_prop_#{:rand.uniform(100_000)}.db")

    # Stop any existing repo
    try do
      GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
    catch
      :exit, _ -> :ok
    end

    {:ok, _pid} =
      Skein.Runtime.Repo.start_link(
        database: db_path,
        pool_size: 1
      )

    {:ok, migration_mod} = MigrationGen.build_migration("ecto_prop_test", @prop_fields)
    :ok = MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)

    {:ok, schema_mod} = EctoSchema.build_schema("ecto_prop_test", @prop_fields)
    StoreEcto.register_schema("ecto_prop_test", schema_mod)

    on_exit(fn ->
      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm(db_path)
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp record_gen do
    gen all(
          id <- id_gen(),
          name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          age <- StreamData.integer(0..120)
        ) do
      %{id: id, name: name, age: age}
    end
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "put then get returns the same record" do
    check all(record <- record_gen()) do
      StoreEcto.clear("ecto_prop_test")
      {:ok, _} = StoreEcto.put("ecto_prop_test", record, @caps)
      {:ok, fetched} = StoreEcto.get("ecto_prop_test", record.id, @caps)
      assert fetched.id == record.id
      assert fetched.name == record.name
      assert fetched.age == record.age
    end
  end

  property "put then delete then get returns not_found" do
    check all(record <- record_gen()) do
      StoreEcto.clear("ecto_prop_test")
      {:ok, _} = StoreEcto.put("ecto_prop_test", record, @caps)
      {:ok, _} = StoreEcto.delete("ecto_prop_test", record.id, @caps)
      assert {:error, "not_found"} = StoreEcto.get("ecto_prop_test", record.id, @caps)
    end
  end

  property "put overwrites previous record with same id" do
    check all(
            id <- id_gen(),
            name1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            name2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            age <- StreamData.integer(0..120)
          ) do
      StoreEcto.clear("ecto_prop_test")
      {:ok, _} = StoreEcto.put("ecto_prop_test", %{id: id, name: name1, age: age}, @caps)
      {:ok, _} = StoreEcto.put("ecto_prop_test", %{id: id, name: name2, age: age}, @caps)
      {:ok, record} = StoreEcto.get("ecto_prop_test", id, @caps)
      assert record.name == name2
    end
  end

  property "query with empty filters returns all records" do
    check all(records <- StreamData.list_of(record_gen(), min_length: 0, max_length: 5)) do
      StoreEcto.clear("ecto_prop_test")

      # Deduplicate by id (last wins)
      unique =
        records
        |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r.id, r) end)
        |> Map.values()

      Enum.each(unique, fn r -> StoreEcto.put("ecto_prop_test", r, @caps) end)

      results = StoreEcto.query("ecto_prop_test", %{}, @caps)
      assert length(results) == length(unique)
    end
  end

  property "operations on undeclared table always return error" do
    check all(id <- id_gen()) do
      empty_caps = []
      assert {:error, _} = StoreEcto.get("ecto_prop_test", id, empty_caps)

      assert {:error, _} =
               StoreEcto.put("ecto_prop_test", %{id: id, name: "x", age: 1}, empty_caps)

      assert {:error, _} = StoreEcto.delete("ecto_prop_test", id, empty_caps)
      assert {:error, _} = StoreEcto.query("ecto_prop_test", %{}, empty_caps)
    end
  end
end
