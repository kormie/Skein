defmodule Skein.Runtime.Idempotent do
  @moduledoc """
  Idempotency guard for Skein handlers.

  Tracks processed keys in an ETS table. When `check!/1` is called:
  - If the key has NOT been seen before, it is recorded and `:ok` is returned.
  - If the key HAS been seen, `{:idempotent_skip}` is thrown, causing the
    handler dispatch layer (Handler, Queue, Topic) to silently skip execution.

  ## TTL

  Keys expire after a configurable TTL (default: 1 hour). Expired keys are
  cleaned up lazily on the next `check!/1` call and periodically by the
  cleanup sweep.

  ## Storage

  Uses an ETS table for in-process storage. This is suitable for development
  and single-node deployments. Production deployments should use a durable
  store (future enhancement).
  """

  @table :skein_idempotent_keys
  @default_ttl_ms :timer.hours(1)

  @doc """
  Checks whether the given key has already been processed.

  If new, records the key and returns `:ok`.
  If already processed, throws `{:idempotent_skip}`.
  """
  @spec check!(String.t()) :: :ok | no_return()
  def check!(key) when is_binary(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()

    case :ets.lookup(@table, key) do
      [{^key, timestamp}] ->
        if now - timestamp < ttl do
          throw({:idempotent_skip})
        else
          # Key has expired — treat as new
          :ets.insert(@table, {key, now})
          :ok
        end

      [] ->
        :ets.insert(@table, {key, now})
        :ok
    end
  end

  @doc """
  Checks whether a key has been processed (without throwing).

  Returns `true` if the key has been processed and is still within TTL,
  `false` otherwise.
  """
  @spec processed?(String.t()) :: boolean()
  def processed?(key) when is_binary(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    ttl = ttl_ms()

    case :ets.lookup(@table, key) do
      [{^key, timestamp}] -> now - timestamp < ttl
      _ -> false
    end
  end

  @doc """
  Removes a key from the processed set, allowing it to be reprocessed.
  """
  @spec clear(String.t()) :: :ok
  def clear(key) when is_binary(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Removes all processed keys. Used in tests.
  """
  @spec reset_all() :: :ok
  def reset_all do
    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Removes expired keys from the table.
  """
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    cutoff = now - ttl_ms()

    # Match all entries with timestamps older than cutoff
    expired =
      :ets.select(@table, [
        {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp ensure_table do
    try do
      :ets.new(@table, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end
  end

  defp ttl_ms do
    Application.get_env(:skein_runtime, :idempotent_ttl_ms, @default_ttl_ms)
  end
end
