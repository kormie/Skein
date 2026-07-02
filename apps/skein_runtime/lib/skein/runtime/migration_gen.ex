defmodule Skein.Runtime.MigrationGen do
  @moduledoc """
  Generates Ecto migrations from Skein type declarations.

  When a Skein module declares `capability store.table("users", User)` and defines
  the `User` type for that table, the compiler extracts field information. This module
  turns that into runnable Ecto migrations that create and modify database tables.

  ## Annotations

  - `@primary` → primary key column
  - `@unique` → unique index on the column
  """

  alias Skein.Runtime.EctoSchema

  @doc """
  Generates migration source code for creating a table.

  Returns a string containing the Ecto migration `change/0` body.
  """
  @spec generate_create_table(String.t(), [map()]) :: String.t()
  def generate_create_table(table_name, fields) when is_binary(table_name) do
    EctoSchema.validate_name!(table_name, "table name")
    Enum.each(fields, fn f -> EctoSchema.validate_name!(f.name, "field name") end)
    table_atom = String.to_atom(table_name)

    # Find primary key
    pk_field = Enum.find(fields, fn f -> "primary" in f.annotations end)

    # Build column lines
    column_lines =
      fields
      |> Enum.map(fn field ->
        ecto_type = EctoSchema.skein_type_to_ecto(field.type)

        if pk_field && field.name == pk_field.name do
          "      add :#{field.name}, :#{ecto_type}, primary_key: true"
        else
          "      add :#{field.name}, :#{ecto_type}"
        end
      end)
      |> Enum.join("\n")

    # Build unique index lines
    unique_fields =
      fields
      |> Enum.filter(fn f -> "unique" in f.annotations end)
      |> Enum.map(fn f ->
        "    create unique_index(:#{table_atom}, [:#{f.name}])"
      end)
      |> Enum.join("\n")

    # Primary key option for create table
    pk_option =
      if pk_field do
        ", primary_key: false"
      else
        ""
      end

    table_block = """
        create table(:#{table_atom}#{pk_option}) do
    #{column_lines}
        end
    """

    if unique_fields != "" do
      table_block <> "\n" <> unique_fields
    else
      String.trim_trailing(table_block)
    end
  end

  @doc """
  Builds a dynamic Ecto migration module for creating a table.

  Returns `{:ok, module}` where the module implements `up/0` and `down/0`.
  """
  @spec build_migration(String.t(), [map()]) :: {:ok, module()} | {:error, String.t()}
  def build_migration(table_name, fields) when is_binary(table_name) do
    EctoSchema.validate_name!(table_name, "table name")
    Enum.each(fields, fn f -> EctoSchema.validate_name!(f.name, "field name") end)
    table_atom = String.to_atom(table_name)

    # Find primary key
    pk_field = Enum.find(fields, fn f -> "primary" in f.annotations end)

    # Build column specs for the migration
    column_specs =
      Enum.map(fields, fn field ->
        field_atom = String.to_atom(field.name)
        ecto_type = EctoSchema.skein_type_to_ecto(field.type)

        is_pk = pk_field != nil && field.name == pk_field.name
        {field_atom, ecto_type, is_pk}
      end)

    # Unique fields
    unique_field_atoms =
      fields
      |> Enum.filter(fn f -> "unique" in f.annotations end)
      |> Enum.map(fn f -> String.to_atom(f.name) end)

    has_custom_pk = pk_field != nil

    module_name = migration_module_name(table_name)

    contents =
      quote do
        use Ecto.Migration

        def up do
          create table(unquote(table_atom), primary_key: unquote(!has_custom_pk)) do
            unquote(
              for {name, type, is_pk} <- column_specs do
                if is_pk do
                  quote do
                    add(unquote(name), unquote(type), primary_key: true)
                  end
                else
                  quote do
                    add(unquote(name), unquote(type))
                  end
                end
              end
            )
          end

          unquote(
            for field_atom <- unique_field_atoms do
              quote do
                create(unique_index(unquote(table_atom), [unquote(field_atom)]))
              end
            end
          )
        end

        def down do
          drop(table(unquote(table_atom)))
        end
      end

    Module.create(module_name, contents, Macro.Env.location(__ENV__))
    {:ok, module_name}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @doc """
  Executes a migration module against the given Repo.

  Runs the migration's `up/0` function within a migration runner context.
  """
  @spec run_migration(module(), module()) :: :ok | {:error, String.t()}
  def run_migration(repo, migration_module) do
    Ecto.Migrator.up(repo, unique_version(), migration_module, log: false)
    :ok
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  # Generate a unique version number for the migration. Second granularity
  # is NOT unique enough: migrating two tables within the same second gave
  # both the same version, and Ecto.Migrator silently skipped the second as
  # already-applied — its table was never created. Millisecond time keeps
  # versions increasing across VM restarts; the unique-integer suffix
  # disambiguates within one.
  defp unique_version do
    System.system_time(:millisecond) * 1000 + rem(System.unique_integer([:positive]), 1000)
  end

  defp migration_module_name(table_name) do
    camel =
      table_name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()

    Module.concat([Skein, Store, Migration, :"Create#{camel}"])
  end
end
