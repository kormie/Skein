defmodule Skein.Runtime.EctoSchemaTest do
  @moduledoc """
  Tests for Skein.Runtime.EctoSchema — generates Ecto schema modules
  from Skein type declarations at compile time.
  """
  use ExUnit.Case, async: true

  alias Skein.Runtime.EctoSchema

  # ------------------------------------------------------------------
  # Schema module generation
  # ------------------------------------------------------------------

  describe "build_schema/3" do
    test "generates an Ecto schema module for a simple type" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("users", fields, repo: Skein.Runtime.Repo)

      # Module should be created and have Ecto schema functions
      assert function_exported?(module, :__schema__, 1)
      assert function_exported?(module, :__schema__, 2)

      # Check field names
      field_names = module.__schema__(:fields)
      assert :id in field_names
      assert :email in field_names
      assert :name in field_names
    end

    test "maps Skein types to Ecto types correctly" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "count", type: "Int", annotations: []},
        %{name: "score", type: "Float", annotations: []},
        %{name: "active", type: "Bool", annotations: []},
        %{name: "label", type: "String", annotations: []},
        %{name: "created_at", type: "Instant", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("typed_records", fields, repo: Skein.Runtime.Repo)

      assert module.__schema__(:type, :id) == :binary_id
      assert module.__schema__(:type, :count) == :integer
      assert module.__schema__(:type, :score) == :float
      assert module.__schema__(:type, :active) == :boolean
      assert module.__schema__(:type, :label) == :string
      assert module.__schema__(:type, :created_at) == :utc_datetime
    end

    test "sets the table name from the store table capability" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("products", fields, repo: Skein.Runtime.Repo)

      assert module.__schema__(:source) == "products"
    end

    test "handles primary key annotation" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("pk_test", fields, repo: Skein.Runtime.Repo)

      primary_keys = module.__schema__(:primary_key)
      assert primary_keys == [:id]
    end

    test "generates a unique module name based on table name" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module1} = EctoSchema.build_schema("table_alpha", fields, repo: Skein.Runtime.Repo)
      {:ok, module2} = EctoSchema.build_schema("table_beta", fields, repo: Skein.Runtime.Repo)

      assert module1 != module2
      assert to_string(module1) =~ "TableAlpha"
      assert to_string(module2) =~ "TableBeta"
    end

    test "handles Option type as nullable field" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "nickname", type: "Option[String]", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("optional_test", fields, repo: Skein.Runtime.Repo)

      # Optional fields should still be defined
      assert :nickname in module.__schema__(:fields)
    end
  end

  # ------------------------------------------------------------------
  # Type mapping
  # ------------------------------------------------------------------

  describe "skein_type_to_ecto/1" do
    test "maps primitive types" do
      assert EctoSchema.skein_type_to_ecto("String") == :string
      assert EctoSchema.skein_type_to_ecto("Int") == :integer
      assert EctoSchema.skein_type_to_ecto("Float") == :float
      assert EctoSchema.skein_type_to_ecto("Bool") == :boolean
      assert EctoSchema.skein_type_to_ecto("Uuid") == :binary_id
      assert EctoSchema.skein_type_to_ecto("Instant") == :utc_datetime
    end

    test "maps Option[T] to inner type" do
      assert EctoSchema.skein_type_to_ecto("Option[String]") == :string
      assert EctoSchema.skein_type_to_ecto("Option[Int]") == :integer
    end

    test "falls back to :string for unknown types" do
      assert EctoSchema.skein_type_to_ecto("CustomType") == :string
    end
  end

  # ------------------------------------------------------------------
  # Changeset generation
  # ------------------------------------------------------------------

  describe "changeset/2" do
    test "builds a changeset from a map" do
      fields = [
        %{name: "id", type: "Uuid", annotations: ["primary"]},
        %{name: "email", type: "String", annotations: ["unique"]},
        %{name: "name", type: "String", annotations: []}
      ]

      {:ok, module} = EctoSchema.build_schema("cs_test", fields, repo: Skein.Runtime.Repo)

      struct = struct(module)
      changeset = module.changeset(struct, %{email: "test@example.com", name: "Alice"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :email) == "test@example.com"
      assert Ecto.Changeset.get_change(changeset, :name) == "Alice"
    end
  end
end
