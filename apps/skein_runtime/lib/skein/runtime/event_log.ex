defmodule Skein.Runtime.EventLog do
  @moduledoc """
  Deprecated: Use `Skein.Runtime.EventStore` directly.

  This module exists only for backward compatibility. All functions delegate
  to EventStore. New code should use EventStore directly — compiled Skein code
  now calls `EventStore.log/3` for `event.log()` effects.
  """

  alias Skein.Runtime.EventStore

  @doc false
  defdelegate log(event_name, data, capabilities), to: EventStore

  @doc false
  def all, do: EventStore.query(kind: :user_event)

  @doc false
  def query(event_name), do: EventStore.query(kind: :user_event, event: event_name)

  @doc false
  def count, do: EventStore.count(kind: :user_event)

  @doc false
  def reset_all, do: EventStore.clear()
end
