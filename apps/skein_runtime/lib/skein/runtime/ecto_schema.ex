defmodule Skein.Runtime.EctoSchema do
  @moduledoc """
  Generates Ecto schema modules from Skein type declarations.

  At compile time, the Skein codegen extracts type field information
  (name, type, annotations) from types used with `store.table` capabilities.
  This module creates dynamic Ecto schema modules that map those fields to
  database columns.

  ## Type Mapping

  | Skein Type   | Ecto Type        | SQLite Column    |
  |-------------|------------------|------------------|
  | String      | :string          | TEXT             |
  | Int         | :integer         | INTEGER          |
  | Float       | :float           | REAL             |
  | Bool        | :boolean         | INTEGER (0/1)    |
  | Uuid        | :binary_id       | TEXT (UUID)       |
  | Instant     | :utc_datetime    | TEXT (ISO8601)    |
  | Duration    | :string          | TEXT             |
  | Email       | :string          | TEXT             |
  | Url         | :string          | TEXT             |
  | Option[T]   | (inner type)     | nullable column  |

  ## Annotations

  - `@primary` → Ecto primary key
  - `@unique` → unique constraint (enforced at migration level)
  """

  @name_format ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @max_name_length 64

  @doc """
  Validates that a table or field name is a safe identifier before it is
  converted to an atom (atoms are never garbage-collected, so unchecked
  conversion of arbitrary strings can exhaust the atom table).

  Raises `ArgumentError` for names that are not `[a-zA-Z_][a-zA-Z0-9_]*`
  or exceed #{@max_name_length} bytes.
  """
  @spec validate_name!(String.t(), String.t()) :: :ok
  def validate_name!(name, kind \\ "name") when is_binary(name) do
    if byte_size(name) <= @max_name_length and Regex.match?(@name_format, name) do
      :ok
    else
      raise ArgumentError,
            "invalid #{kind} #{inspect(name)}: must match [a-zA-Z_][a-zA-Z0-9_]* " <>
              "and be at most #{@max_name_length} bytes"
    end
  end

  @doc """
  Generates a dynamic Ecto schema module for the given table and field definitions.

  Fields are maps with keys: `name` (string), `type` (Skein type string),
  `annotations` (list of annotation name strings).

  Options:
    - `:repo` — the Ecto Repo module (default: `Skein.Runtime.Repo`)

  Returns `{:ok, module_atom}` or `{:error, reason}`.
  """
  @spec build_schema(String.t(), [map()], keyword()) :: {:ok, module()} | {:error, String.t()}
  def build_schema(table_name, fields, opts \\ []) when is_binary(table_name) do
    _repo = Keyword.get(opts, :repo, Skein.Runtime.Repo)
    validate_name!(table_name, "table name")
    Enum.each(fields, fn f -> validate_name!(f.name, "field name") end)
    module_name = module_name_for(table_name)

    # Find primary key field (or default to :id)
    primary_field =
      Enum.find(fields, fn f -> "primary" in f.annotations end)
      |> case do
        nil -> "id"
        f -> f.name
      end

    primary_key_atom = String.to_atom(primary_field)
    primary_type = find_field_type(fields, primary_field)

    # Build non-primary field definitions
    non_pk_fields =
      fields
      |> Enum.reject(fn f -> f.name == primary_field end)
      |> Enum.map(fn f ->
        {String.to_atom(f.name), skein_type_to_ecto(f.type)}
      end)

    # All field atoms for changeset cast (including primary key for explicit id assignment)
    all_field_atoms =
      fields
      |> Enum.map(fn f -> String.to_atom(f.name) end)

    # Option[...]-declared fields, exposed as module metadata so the store
    # can convert between the total in-language representation ({:some, v} /
    # :none) and the nullable column (value / NULL) on both sides of the
    # round trip (#294).
    option_field_atoms =
      fields
      |> Enum.filter(fn f -> String.starts_with?(f.type, "Option[") end)
      |> Enum.map(fn f -> String.to_atom(f.name) end)

    # Build the module dynamically
    contents =
      quote do
        use Ecto.Schema

        @primary_key {unquote(primary_key_atom), unquote(primary_type), autogenerate: false}

        schema unquote(table_name) do
          unquote(
            for {name, type} <- non_pk_fields do
              quote do
                field(unquote(name), unquote(type))
              end
            end
          )
        end

        def changeset(struct, params) do
          struct
          |> Ecto.Changeset.cast(params, unquote(all_field_atoms))
        end

        def __skein_option_fields__ do
          unquote(option_field_atoms)
        end
      end

    Module.create(module_name, contents, Macro.Env.location(__ENV__))
    {:ok, module_name}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @doc """
  Maps a Skein type string to an Ecto schema type atom.
  """
  @spec skein_type_to_ecto(String.t()) :: atom()
  def skein_type_to_ecto(type) when is_binary(type) do
    case type do
      "String" -> :string
      "Int" -> :integer
      "Float" -> :float
      "Bool" -> :boolean
      "Uuid" -> :binary_id
      "Instant" -> :utc_datetime
      "Duration" -> :string
      "Email" -> :string
      "Url" -> :string
      "Option[" <> rest -> skein_type_to_ecto(String.trim_trailing(rest, "]"))
      _ -> :string
    end
  end

  @doc """
  Returns the Ecto schema module name for a given table name.

  Converts snake_case table names to CamelCase module names under
  the `Skein.Store.Schema` namespace.
  """
  @spec module_name_for(String.t()) :: module()
  def module_name_for(table_name) do
    camel =
      table_name
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()

    Module.concat([Skein, Store, Schema, camel])
  end

  # Find the Ecto type for a field by name
  defp find_field_type(fields, field_name) do
    case Enum.find(fields, fn f -> f.name == field_name end) do
      nil -> :binary_id
      f -> skein_type_to_ecto(f.type)
    end
  end
end
