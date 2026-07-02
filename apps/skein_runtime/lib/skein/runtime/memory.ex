defmodule Skein.Runtime.Memory do
  @moduledoc """
  Runtime scoped KV memory for Skein agents and modules.

  Provides per-namespace key-value storage used by `memory.put`, `memory.get`,
  `memory.delete`, and `memory.list` effect calls in Skein source
  (`memory.get(key)!` unwraps via the postfix `!` operator).

  ## Dual Storage Architecture

  Memory uses two storage layers:

  1. **ETS cache** — a single ETS table (`:skein_memory`) keyed by
     `{namespace, key}` for fast read/write access. Using one static table
     means namespace strings are never converted to atoms (atoms are never
     garbage-collected, so dynamic atom creation is a leak)
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

  @table :skein_memory

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
          scoped = scope_key(key)
          ensure_table()
          :ets.insert(@table, {{namespace, scoped}, value})

          EventStore.append(%{
            kind: :state_change,
            namespace: namespace,
            operation: :put,
            key: scoped,
            value: value
          })

          {:ok, value}

        {:error, reason} ->
          # MemoryError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
      end
    end)
  end

  @doc """
  Retrieves a value by key from the specified namespace.

  Returns `{:ok, value}` or `{:error, :not_found}`. The miss value is the atom
  `:not_found` so it matches the spec's `Result[T, NotFound]` contract — the
  `Err(NotFound)` pattern lowers to `{:error, :not_found}` (skein-testing#3).
  """
  @spec get(String.t(), String.t(), [map()]) :: {:ok, any()} | {:error, :not_found | String.t()}
  def get(namespace, key, capabilities)
      when is_binary(namespace) and is_binary(key) and is_list(capabilities) do
    Trace.with_span(%{kind: :memory, method: :get, namespace: namespace}, fn ->
      case check_memory_capability(namespace, capabilities) do
        :ok ->
          scoped = scope_key(key)
          ensure_table()

          case :ets.lookup(@table, {namespace, scoped}) do
            [{{^namespace, ^scoped}, value}] -> {:ok, value}
            [] -> {:error, :not_found}
          end

        {:error, reason} ->
          # MemoryError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
      end
    end)
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
          scoped = scope_key(key)
          ensure_table()
          :ets.delete(@table, {namespace, scoped})

          EventStore.append(%{
            kind: :state_change,
            namespace: namespace,
            operation: :delete,
            key: scoped
          })

          {:ok, key}

        {:error, reason} ->
          # MemoryError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
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
          ensure_table()

          instance_prefix = agent_prefix()

          :ets.match(@table, {{namespace, :"$1"}, :_})
          |> Enum.map(fn [key] -> key end)
          |> Enum.filter(fn key ->
            # Filter to current agent instance's keys if in agent context
            in_scope =
              if instance_prefix, do: String.starts_with?(key, instance_prefix), else: true

            # Apply user prefix filter on the unscoped key
            unscoped =
              if instance_prefix && in_scope,
                do: String.replace_prefix(key, instance_prefix, ""),
                else: key

            in_scope && (prefix == "" || prefix == "*" || String.starts_with?(unscoped, prefix))
          end)
          |> Enum.map(&unscope_key/1)

        {:error, reason} ->
          # MemoryError.Denied(reason) — the frozen ABI form (C2/#297).
          {:error, {:denied, reason}}
      end
    end)
  end

  @doc """
  Clears all entries from a namespace. Used in testing.
  """
  @spec clear(String.t()) :: :ok
  def clear(namespace) when is_binary(namespace) do
    ensure_table()
    :ets.match_delete(@table, {{namespace, :_}, :_})
    :ok
  end

  @doc """
  Clears every namespace's entries. The test runner calls this between scenarios
  so memory state never leaks from one test to the next (#283).
  """
  @spec clear_all() :: :ok
  def clear_all do
    ensure_table()
    :ets.delete_all_objects(@table)
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

  defp ensure_table do
    Skein.Runtime.EtsTables.ensure_table(
      @table,
      [:named_table, :set, :public, read_concurrency: true]
    )
  end

  # Scope a key with the agent instance prefix if running inside an agent process.
  # This provides automatic isolation between concurrent agent instances.
  defp scope_key(key) do
    case {Process.get(:skein_agent_name), Process.get(:skein_agent_instance_id)} do
      {name, id} when is_binary(name) and is_binary(id) ->
        "#{name}:#{id}:#{key}"

      _ ->
        key
    end
  end

  # Strip the agent instance prefix from a scoped key to return the user-facing key.
  defp unscope_key(scoped_key) do
    case {Process.get(:skein_agent_name), Process.get(:skein_agent_instance_id)} do
      {name, id} when is_binary(name) and is_binary(id) ->
        prefix = "#{name}:#{id}:"

        if String.starts_with?(scoped_key, prefix) do
          String.replace_prefix(scoped_key, prefix, "")
        else
          scoped_key
        end

      _ ->
        scoped_key
    end
  end

  # Returns the agent instance prefix for filtering in list operations, or nil.
  defp agent_prefix do
    case {Process.get(:skein_agent_name), Process.get(:skein_agent_instance_id)} do
      {name, id} when is_binary(name) and is_binary(id) -> "#{name}:#{id}:"
      _ -> nil
    end
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
