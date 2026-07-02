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

  Returns `{:ok, record}` or `{:error, :not_found}`. The miss value is the
  atom `:not_found` so it matches the spec's `Result[T, NotFound]` contract —
  the `Err(NotFound)` pattern lowers to `{:error, :not_found}` (skein-testing#3).
  """
  @spec get(String.t(), any(), [map()]) :: {:ok, map()} | {:error, :not_found | String.t()}
  def get(table_name, id, capabilities) when is_binary(table_name) and is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :get, table: table_name}, fn ->
      case check_store_capability(table_name, capabilities) do
        :ok ->
          ensure_table()

          case :ets.lookup(@table, {table_name, id}) do
            [{{^table_name, ^id}, record}] -> {:ok, record}
            [] -> {:error, :not_found}
          end

        {:error, reason} ->
          # StoreError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
      end
    end)
  end

  @doc """
  Inserts or updates a record, keyed by its primary field.

  Direct Elixir callers default the primary field to `"id"`; compiled
  Skein code threads the record type's declared `@primary` field name
  (see `put/5`). Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec put(String.t(), map(), [map()]) :: {:ok, map()} | {:error, tuple()}
  def put(table_name, record, capabilities)
      when is_binary(table_name) and is_map(record) and is_list(capabilities) do
    put(table_name, record, nil, "id", capabilities)
  end

  @doc """
  Inserts or updates a record, schema-checking it first (C5/#255).

  Compiled `store.<table>.put(record)` calls land here: the compiler
  threads the table's derived JSON Schema (from the typed
  `capability store.table("name", RecordType)` declaration) so every
  write is validated — defense in depth behind the analyzer's record
  typing, and a real gate for data that reached the record through
  dynamic seams. A `nil` schema skips validation (direct Elixir callers).

  A schema violation is `{:error, {:failed, reason}}` —
  `StoreError.Failed(reason)` in Skein.
  """
  @spec put(String.t(), map(), map() | nil, [map()]) :: {:ok, map()} | {:error, tuple()}
  def put(table_name, record, schema, capabilities)
      when is_binary(table_name) and is_map(record) and is_list(capabilities) do
    put(table_name, record, schema, "id", capabilities)
  end

  @doc """
  Inserts or updates a record, schema-checked and keyed by the declared
  primary field (#340).

  Compiled `store.<table>.put(record)` calls land here: alongside the
  derived JSON Schema, the compiler threads the record type's `@primary`
  field name (the analyzer guarantees exactly one, E0043), so tables
  whose primary is not named `id` — `sku: String @primary` — key their
  rows by the declared field, exactly as spec §3.2/§6.2 promise.
  """
  @spec put(String.t(), map(), map() | nil, String.t(), [map()]) ::
          {:ok, map()} | {:error, tuple()}
  def put(table_name, record, schema, primary_field, capabilities)
      when is_binary(table_name) and is_map(record) and is_binary(primary_field) and
             is_list(capabilities) do
    Trace.with_span(%{kind: :store, method: :put, table: table_name}, fn ->
      with :ok <- check_store_capability(table_name, capabilities) |> denied(),
           :ok <- check_record_schema(record, schema) do
        ensure_table()

        case extract_primary(record, primary_field) do
          nil ->
            {:error,
             {:failed, "Record must have a value for its primary field '#{primary_field}'"}}

          key ->
            :ets.insert(@table, {{table_name, key}, record})
            {:ok, record}
        end
      end
    end)
  end

  # StoreError.Denied(reason) — the frozen ABI form (C2/#297).
  defp denied(:ok), do: :ok
  defp denied({:error, reason}), do: {:error, {:denied, reason}}

  defp check_record_schema(_record, nil), do: :ok

  defp check_record_schema(record, schema) when is_map(schema) do
    case Skein.Runtime.JsonSchema.validate(record, schema) do
      :ok ->
        :ok

      {:error, violations} ->
        {:error, {:failed, "record violates the table's schema: " <> Enum.join(violations, "; ")}}
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

        {:error, reason} ->
          # StoreError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
      end
    end)
  end

  @doc """
  Queries records matching the given filters.

  Filters is a map of field names (atoms or strings) to values.
  Returns all records where every filter field matches.

  Returns `{:ok, records}` with the matching records (the list may be
  empty), or `{:error, reason}` when the `store` capability is missing or
  a filter names a field the table's records don't have. Surfacing an
  unknown filter field as an error (rather than silently returning `[]`)
  keeps typos and bad column names from masquerading as "no results", and
  makes `!`/`?` fail loudly. Returning a Result also keeps
  `store.<table>.query(...)` consistent with `get`/`put`/`delete`.
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

          case validate_filter_keys(table_name, records, filters) do
            :ok ->
              {:ok, Enum.filter(records, fn record -> matches_filters?(record, filters) end)}

            {:error, _} = error ->
              error
          end

        {:error, reason} ->
          # StoreError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
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

  @doc """
  Clears every table's records. The test runner calls this between scenarios so
  store state never leaks from one test to the next (#283).
  """
  @spec clear_all() :: :ok
  def clear_all do
    ensure_table()
    :ets.delete_all_objects(@table)
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

  # The primary field name arrives as a string from compiled literals;
  # compiled records are atom-keyed, direct callers may pass either.
  defp extract_primary(record, primary_field) when is_map(record) do
    Map.get(record, String.to_atom(primary_field)) || Map.get(record, primary_field)
  end

  # Validate that every filter key names a field the table actually has.
  #
  # The ETS store is schemaless, so the table's field set is reconstructed
  # from the keys present across its stored records. An unknown filter key
  # (a typo or bad column) returns an error instead of silently matching no
  # rows. When the table holds no records there is no schema to validate
  # against, so any filter is allowed (the query simply yields no matches).
  defp validate_filter_keys(table_name, records, filters) do
    known = known_fields(records)

    if MapSet.size(known) == 0 do
      :ok
    else
      unknown =
        filters
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.reject(fn key -> MapSet.member?(known, key) end)

      case unknown do
        [] ->
          :ok

        keys ->
          allowed = known |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

          {:error,
           {:failed,
            "Unknown filter field#{plural(keys)} #{Enum.map_join(keys, ", ", &inspect/1)} " <>
              "for query on table '#{table_name}'. Allowed fields: #{allowed}"}}
      end
    end
  end

  # The union of field names (as strings) across all stored records.
  defp known_fields(records) do
    Enum.reduce(records, MapSet.new(), fn record, acc ->
      record
      |> Map.keys()
      |> Enum.reduce(acc, fn key, inner -> MapSet.put(inner, to_string(key)) end)
    end)
  end

  defp plural([_]), do: ""
  defp plural(_), do: "s"

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
