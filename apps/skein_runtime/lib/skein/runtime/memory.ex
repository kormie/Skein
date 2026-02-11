defmodule Skein.Runtime.Memory do
  @moduledoc """
  Runtime scoped KV memory for Skein agents and modules.

  Provides per-namespace key-value storage used by `memory.put`, `memory.get`,
  `memory.get!`, `memory.delete`, and `memory.list` effect calls in Skein source.

  ## Dual Storage Architecture

  Memory uses two storage layers:

  1. **ETS cache** — per-namespace ETS tables for fast read/write access
  2. **EventStore** — each mutation (put/delete) appends a `:state_change` event
     to the unified event log

  The ETS cache is the primary read path for performance. The EventStore events
  provide an audit trail and enable memory reconstruction from the event stream
  (see `rebuild_from_events/1`).

  Every operation is:
  1. Checked against the module's declared `memory.kv` capabilities
  2. Traced with timing, metadata, and outcome (via `Trace.with_span`)
  3. Mutations also emit a `:state_change` event with the key/value data
  4. Returns `{:ok, result}` or `{:error, reason}`

  This module is called by compiled Skein code — the codegen emits calls like
  `Skein.Runtime.Memory.put("sessions", key, value, capabilities)`.
  """

  alias Skein.Runtime.Trace
  alias Skein.Runtime.EventStore

  @doc """
  Stores a value under the given key in the specified namespace.

  Returns `{:ok, value}` on success or `{:error, reason}` on failure.
  """
  @spec put(String.t(), String.t(), any(), [map()]) :: {:ok, any()} | {:error, String.t()}
  def put(namespace, key, value, capabilities)
      when is_binary(namespace) and is_binary(key) and is_list(capabilities) do
    Trace.with_span(%{kind: :memory, method: :put, namespace: namespace}, fn ->
      case check_memory_capability(namespace, capabilities) do
        :ok ->
          ets_table = table_ref(namespace)
          ensure_table(ets_table)
          :ets.insert(ets_table, {key, value})

          EventStore.append(%{
            kind: :state_change,
            namespace: namespace,
            operation: :put,
            key: key,
            value: value
          })

          {:ok, value}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Retrieves a value by key from the specified namespace.

  Returns `{:ok, value}` or `{:error, "not_found"}`.
  """
  @spec get(String.t(), String.t(), [map()]) :: {:ok, any()} | {:error, String.t()}
  def get(namespace, key, capabilities)
      when is_binary(namespace) and is_binary(key) and is_list(capabilities) do
    Trace.with_span(%{kind: :memory, method: :get, namespace: namespace}, fn ->
      case check_memory_capability(namespace, capabilities) do
        :ok ->
          ets_table = table_ref(namespace)
          ensure_table(ets_table)

          case :ets.lookup(ets_table, key) do
            [{^key, value}] -> {:ok, value}
            [] -> {:error, "not_found"}
          end

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Retrieves a value by key, raising on missing key or missing capability.

  Returns the value directly or raises `RuntimeError`.
  """
  @spec get!(String.t(), String.t(), [map()]) :: any()
  def get!(namespace, key, capabilities)
      when is_binary(namespace) and is_binary(key) and is_list(capabilities) do
    case get(namespace, key, capabilities) do
      {:ok, value} -> value
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  @doc """
  Deletes a key from the specified namespace.

  Returns `{:ok, key}` on success or `{:error, reason}` on failure.
  """
  @spec delete(String.t(), String.t(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def delete(namespace, key, capabilities)
      when is_binary(namespace) and is_binary(key) and is_list(capabilities) do
    Trace.with_span(%{kind: :memory, method: :delete, namespace: namespace}, fn ->
      case check_memory_capability(namespace, capabilities) do
        :ok ->
          ets_table = table_ref(namespace)
          ensure_table(ets_table)
          :ets.delete(ets_table, key)

          EventStore.append(%{
            kind: :state_change,
            namespace: namespace,
            operation: :delete,
            key: key
          })

          {:ok, key}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Lists all keys in the namespace matching the given prefix.

  Returns a list of key strings, or `{:error, reason}` on capability failure.
  """
  @spec list(String.t(), String.t(), [map()]) :: [String.t()] | {:error, String.t()}
  def list(namespace, prefix, capabilities)
      when is_binary(namespace) and is_binary(prefix) and is_list(capabilities) do
    Trace.with_span(%{kind: :memory, method: :list, namespace: namespace}, fn ->
      case check_memory_capability(namespace, capabilities) do
        :ok ->
          ets_table = table_ref(namespace)
          ensure_table(ets_table)

          :ets.tab2list(ets_table)
          |> Enum.map(fn {key, _value} -> key end)
          |> Enum.filter(fn key -> String.starts_with?(key, prefix) end)

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Clears all entries from a namespace. Used in testing.
  """
  @spec clear(String.t()) :: :ok
  def clear(namespace) when is_binary(namespace) do
    ets_table = table_ref(namespace)
    ensure_table(ets_table)
    :ets.delete_all_objects(ets_table)
    :ok
  end

  @doc """
  Rebuilds memory state for a namespace from the unified event stream.

  Replays all `:state_change` events for the given namespace in chronological
  order, applying puts and deletes to reconstruct the current state.

  Returns a map of `%{key => value}` representing the reconstructed state.

  This enables event-sourced memory: the ETS cache is an optimization,
  but the event log is the source of truth.
  """
  @spec rebuild_from_events(String.t()) :: %{String.t() => any()}
  def rebuild_from_events(namespace) when is_binary(namespace) do
    EventStore.query(kind: :state_change, namespace: namespace)
    # query returns newest first; reverse to get chronological order
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn event, acc ->
      case event.operation do
        :put -> Map.put(acc, event.key, event.value)
        :delete -> Map.delete(acc, event.key)
      end
    end)
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp table_ref(namespace) do
    String.to_atom("skein_memory_#{namespace}")
  end

  defp ensure_table(ets_table) do
    if :ets.whereis(ets_table) == :undefined do
      :ets.new(ets_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  defp check_memory_capability(namespace, capabilities) do
    memory_caps =
      Enum.filter(capabilities, fn cap ->
        cap.kind == "memory.kv"
      end)

    case memory_caps do
      [] ->
        {:error,
         "Memory capability 'memory.kv(\"#{namespace}\")' not declared. " <>
           "Memory operations on '#{namespace}' blocked."}

      caps ->
        has_wildcard = Enum.any?(caps, fn cap -> cap.params == [] end)

        if has_wildcard do
          :ok
        else
          allowed_namespaces =
            caps
            |> Enum.flat_map(fn cap -> cap.params end)

          if namespace in allowed_namespaces do
            :ok
          else
            {:error,
             "Namespace '#{namespace}' not declared in memory.kv capabilities. " <>
               "Allowed namespaces: #{Enum.join(allowed_namespaces, ", ")}"}
          end
        end
    end
  end
end
