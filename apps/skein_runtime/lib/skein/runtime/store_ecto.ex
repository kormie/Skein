defmodule Skein.Runtime.StoreEcto do
  @moduledoc """
  Ecto-backed implementation of Skein store operations.

  This module performs real database operations via Ecto against SQLite
  (or Postgres in production). It maintains a registry of table name →
  Ecto schema module mappings, which are populated at compile time when
  Skein modules with `store.table` capabilities are loaded.

  ## Architecture

  Compiled Skein code calls `Skein.Runtime.Store` which delegates to this
  module when the Ecto backend is active. The schema registry maps table
  names to dynamically-generated Ecto schema modules (created by
  `Skein.Runtime.EctoSchema`).

  Each operation:
  1. Checks capabilities (same logic as the ETS backend)
  2. Looks up the registered schema module for the table
  3. Executes the Ecto query
  4. Records a trace span
  """

  alias Skein.Runtime.Trace

  # Schema registry: table_name -> schema_module
  @registry_table :skein_store_ecto_schemas

  @doc """
  Registers an Ecto schema module for a table name.

  Called during module loading after `EctoSchema.build_schema/3` creates
  the schema module.
  """
  @spec register_schema(String.t(), module()) :: :ok
  def register_schema(table_name, schema_module)
      when is_binary(table_name) and is_atom(schema_module) do
    ensure_registry()
    :ets.insert(@registry_table, {table_name, schema_module})
    :ok
  end

  @doc """
  Looks up the schema module for a table name.
  """
  @spec lookup_schema(String.t()) :: {:ok, module()} | :error
  def lookup_schema(table_name) when is_binary(table_name) do
    ensure_registry()

    case :ets.lookup(@registry_table, table_name) do
      [{^table_name, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Retrieves a record by its primary key.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec get(String.t(), any(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def get(table_name, id, capabilities) when is_binary(table_name) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :get, table: table_name}, fn ->
      with :ok <- check_store_capability(table_name, capabilities),
           {:ok, schema_mod} <- require_schema(table_name) do
        case Skein.Runtime.Repo.get(schema_mod, id) do
          nil -> {:error, "not_found"}
          record -> {:ok, schema_to_map(record)}
        end
      end
    end)
  end

  @doc """
  Inserts or updates a record. Uses upsert semantics — if a record with
  the same primary key exists, it is replaced.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec put(String.t(), map(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def put(table_name, record, capabilities)
      when is_binary(table_name) and is_map(record) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :put, table: table_name}, fn ->
      with :ok <- check_store_capability(table_name, capabilities),
           {:ok, schema_mod} <- require_schema(table_name) do
        changeset = schema_mod.changeset(struct(schema_mod), atomize_keys(record))

        case Skein.Runtime.Repo.insert(changeset,
               on_conflict: :replace_all,
               conflict_target: primary_key_fields(schema_mod)
             ) do
          {:ok, inserted} ->
            {:ok, schema_to_map(inserted)}

          {:error, changeset} ->
            {:error, "Insert failed: #{inspect(changeset.errors)}"}
        end
      end
    end)
  end

  @doc """
  Deletes a record by its primary key.

  Returns `{:ok, id}` or `{:error, reason}`.
  """
  @spec delete(String.t(), any(), [map()]) :: {:ok, any()} | {:error, String.t()}
  def delete(table_name, id, capabilities)
      when is_binary(table_name) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :delete, table: table_name}, fn ->
      with :ok <- check_store_capability(table_name, capabilities),
           {:ok, schema_mod} <- require_schema(table_name) do
        case Skein.Runtime.Repo.get(schema_mod, id) do
          nil ->
            # Silent success for non-existent records (matches ETS behavior)
            {:ok, id}

          record ->
            Skein.Runtime.Repo.delete(record)
            {:ok, id}
        end
      end
    end)
  end

  @doc """
  Queries records matching the given filters.

  Filters is a map of field name (atom or string) to value.
  Returns a list of matching records as maps.
  """
  @spec query(String.t(), map(), [map()]) :: list(map()) | {:error, String.t()}
  def query(table_name, filters, capabilities)
      when is_binary(table_name) and is_map(filters) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :query, table: table_name}, fn ->
      with :ok <- check_store_capability(table_name, capabilities),
           {:ok, schema_mod} <- require_schema(table_name) do
        import Ecto.Query

        query = from(r in schema_mod)

        query =
          Enum.reduce(atomize_keys(filters), query, fn {key, value}, acc ->
            from(r in acc, where: field(r, ^key) == ^value)
          end)

        Skein.Runtime.Repo.all(query)
        |> Enum.map(&schema_to_map/1)
      end
    end)
  end

  @doc """
  Clears all records from a table. Used in testing.
  """
  @spec clear(String.t()) :: :ok
  def clear(table_name) when is_binary(table_name) do
    case lookup_schema(table_name) do
      {:ok, schema_mod} ->
        Skein.Runtime.Repo.delete_all(schema_mod)
        :ok

      :error ->
        :ok
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp ensure_registry do
    if :ets.whereis(@registry_table) == :undefined do
      try do
        :ets.new(@registry_table, [:named_table, :set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp require_schema(table_name) do
    case lookup_schema(table_name) do
      {:ok, _mod} = ok -> ok
      :error -> {:error, "No Ecto schema registered for table '#{table_name}'"}
    end
  end

  defp schema_to_map(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end

  defp primary_key_fields(schema_mod) do
    schema_mod.__schema__(:primary_key)
  end

  defp check_store_capability(table_name, capabilities) do
    store_caps =
      Enum.filter(capabilities, fn cap ->
        cap.kind == "store.table"
      end)

    case store_caps do
      [] ->
        {:error,
         "Store capability 'store.table(\"#{table_name}\")' not declared. " <>
           "Store operations on '#{table_name}' blocked."}

      caps ->
        allowed_tables =
          caps
          |> Enum.flat_map(fn cap -> cap.params end)

        if table_name in allowed_tables do
          :ok
        else
          {:error,
           "Table '#{table_name}' not declared in store.table capabilities. " <>
             "Allowed tables: #{Enum.join(allowed_tables, ", ")}"}
        end
    end
  end
end
