defmodule Skein.Runtime.MigrationGenTest do
  @moduledoc """
  Tests for Skein.Runtime.MigrationGen — generates Ecto migration modules
  from Skein type declarations.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.MigrationGen

  # ------------------------------------------------------------------
  # Migration source generation
  # ------------------------------------------------------------------

  describe "generate_create_table/2" do
    test "generates migration source for a simple table" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "name", type: "String", annotations: []}
      ]

      source = MigrationGen.generate_create_table("users", fields)

      assert source =~ "create table(:users"
      assert source =~ "add :id, :binary_id, primary_key: true"
      assert source =~ "add :email, :string"
      assert source =~ "add :name, :string"
      assert source =~ "create unique_index(:users, [:email])"
    end

    test "generates correct column types for all Skein types" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "count", type: "Int", annotations: []},
        %{name: "score", type: "Float", annotations: []},
        %{name: "active", type: "Bool", annotations: []},
        %{name: "label", type: "String", annotations: []},
        %{name: "created_at", type: "Instant", annotations: []}
      ]

      source = MigrationGen.generate_create_table("typed_table", fields)

      assert source =~ "add :count, :integer"
      assert source =~ "add :score, :float"
      assert source =~ "add :active, :boolean"
      assert source =~ "add :label, :string"
      assert source =~ "add :created_at, :utc_datetime"
    end

    test "generates nullable columns for Option types" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "nickname", type: "Option[String]", annotations: []}
      ]

      source = MigrationGen.generate_create_table("optional_table", fields)

      assert source =~ "add :nickname, :string"
    end

    test "generates multiple unique indexes" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "username", type: "String", annotations: ["unique"]}
      ]

      source = MigrationGen.generate_create_table("multi_unique", fields)

      assert source =~ "create unique_index(:multi_unique, [:email])"
      assert source =~ "create unique_index(:multi_unique, [:username])"
    end

    test "uses Int primary key when type is Int" do
      fields = [
        %{name: "id", type: "Int", annotations: ["primary"]},
        %{name: "name", type: "String", annotations: []}
      ]

      source = MigrationGen.generate_create_table("int_pk", fields)

      assert source =~ "add :id, :integer, primary_key: true"
    end
  end

  # ------------------------------------------------------------------
  # Migration module creation
  # ------------------------------------------------------------------

  describe "build_migration/2" do
    test "creates a runnable migration module" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module} = MigrationGen.build_migration("migration_test", fields)

      assert function_exported?(module, :up, 0)
      assert function_exported?(module, :down, 0)
    end
  end

  # ------------------------------------------------------------------
  # Migration execution against SQLite
  # ------------------------------------------------------------------

  describe "run_migration/2" do
    setup do
      # Create a temp SQLite database for this test
      db_path = Path.join(System.tmp_dir!(), "skein_migration_test_#{:rand.uniform(100_000)}.db")

      # Stop any existing repo first
      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      # Start the repo with default name so Ecto.Migrator can find it
      {:ok, pid} =
        Skein.Runtime.Repo.start_link(
          database: db_path,
          pool_size: 1
        )

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end

        File.rm(db_path)
      end)

      {:ok, db_path: db_path}
    end

    test "creates a table in the database" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, migration_mod} = MigrationGen.build_migration("run_mig_test", fields)

      # Execute the migration
      assert :ok = MigrationGen.run_migration(Skein.Runtime.Repo, migration_mod)

      # Verify the table exists by querying it
      result =
        Ecto.Adapters.SQL.query!(
          Skein.Runtime.Repo,
          "SELECT name FROM sqlite_master WHERE type='table' AND name='run_mig_test'"
        )

      assert length(result.rows) == 1
      assert hd(result.rows) == ["run_mig_test"]
    end
  end
end
