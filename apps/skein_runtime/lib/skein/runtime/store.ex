defmodule Skein.Runtime.Store do
  @moduledoc """
  Runtime store for Skein `store.<table>.<method>` effect calls.

  Provides typed record storage with get, put, delete, and query operations.
  Backed by ETS for local development. All logical tables share a single ETS
  table (`:skein_store`) keyed by `{table_name, id}`, so table names never
  need to be converted to atoms (table names can come from arbitrary program
  input, and atoms are never garbage-collected).

  Every operation is:
  1. Checked against the module's declared capabilities
  2. Traced with timing, metadata, and outcome
  3. Returns `{:ok, result}` or `{:error, reason}`

  This module is called by compiled Skein code — the codegen emits calls like
  `Skein.Runtime.Store.get("users", id, capabilities)`.
  """

  alias Skein.Runtime.Trace

  @table :skein_store

  @doc """
  Retrieves a record by its primary key (id).

  Returns `{:ok, record}` or `{:error, "not_found"}`.
  """
  @spec get(String.t(), any(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def get(table_name, id, capabilities) when is_binary(table_name) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :get, table: table_name}, fn ->
      case check_store_capability(table_name, capabilities) do
        :ok ->
          ensure_table()

          case :ets.lookup(@table, {table_name, id}) do
            [{{^table_name, ^id}, record}] -> {:ok, record}
            [] -> {:error, "not_found"}
          end

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Retrieves a record by its primary key, raising on a missing record or
  missing capability. Backs the `store.<table>.get!(id)` form in Skein
  source (let-it-crash semantics).
  """
  @spec get!(String.t(), any(), [map()]) :: map()
  def get!(table_name, id, capabilities) do
    case get(table_name, id, capabilities) do
      {:ok, record} -> record
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  @doc """
  Inserts or updates a record. The record must be a map with an `:id` field
  (or `"id"` key) used as the primary key.

  Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec put(String.t(), map(), [map()]) :: {:ok, map()} | {:error, String.t()}
  def put(table_name, record, capabilities)
      when is_binary(table_name) and is_map(record) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :put, table: table_name}, fn ->
      case check_store_capability(table_name, capabilities) do
        :ok ->
          ensure_table()

          case extract_id(record) do
            nil ->
              {:error, "Record must have an :id or \"id\" field"}

            id ->
              :ets.insert(@table, {{table_name, id}, record})
              {:ok, record}
          end

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Inserts or updates a record, raising on failure. Backs the
  `store.<table>.put!(record)` form in Skein source.
  """
  @spec put!(String.t(), map(), [map()]) :: map()
  def put!(table_name, record, capabilities) do
    case put(table_name, record, capabilities) do
      {:ok, stored} -> stored
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  @doc """
  Deletes a record by its primary key.

  Returns `{:ok, id}` or `{:error, reason}`.
  """
  @spec delete(String.t(), any(), [map()]) :: {:ok, any()} | {:error, String.t()}
  def delete(table_name, id, capabilities) when is_binary(table_name) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :delete, table: table_name}, fn ->
      case check_store_capability(table_name, capabilities) do
        :ok ->
          ensure_table()
          :ets.delete(@table, {table_name, id})
          {:ok, id}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Queries records matching the given filters.

  Filters is a map of field names (atoms or strings) to values.
  Returns all records where every filter field matches.

  Returns `{:ok, records}` with the matching records (the list may be
  empty), or `{:error, reason}` when the `store` capability is missing.
  Returning a Result keeps `store.<table>.query(...)` consistent with
  `get`/`put`/`delete`, so the `!`/`?` operators behave uniformly.
  """
  @spec query(String.t(), map(), [map()]) :: {:ok, [map()]} | {:error, String.t()}
  def query(table_name, filters, capabilities)
      when is_binary(table_name) and is_map(filters) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :query, table: table_name}, fn ->
      case check_store_capability(table_name, capabilities) do
        :ok ->
          ensure_table()

          records =
            :ets.match_object(@table, {{table_name, :_}, :_})
            |> Enum.map(fn {{_table, _id}, record} -> record end)
            |> Enum.filter(fn record -> matches_filters?(record, filters) end)

          {:ok, records}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Clears all records from a table. Used in testing.
  """
  @spec clear(String.t()) :: :ok
  def clear(table_name) when is_binary(table_name) do
    ensure_table()
    :ets.match_delete(@table, {{table_name, :_}, :_})
    :ok
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp ensure_table do
    Skein.Runtime.EtsTables.ensure_table(
      @table,
      [:named_table, :set, :public, read_concurrency: true]
    )
  end

  defp extract_id(record) when is_map(record) do
    Map.get(record, :id) || Map.get(record, "id")
  end

  defp matches_filters?(record, filters) when is_map(record) and is_map(filters) do
    Enum.all?(filters, fn {key, value} ->
      # Try both atom and string key
      record_value = Map.get(record, key) || Map.get(record, to_string(key))
      record_value == value
    end)
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
