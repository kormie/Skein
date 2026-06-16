defmodule Skein.Runtime.CapabilityStack do
  @moduledoc """
  The dynamic scenario capability-context stack (#282, foundation).

  Scenario capability envelopes are *tool-execution scoped*: while a tool runs
  under `tool.call(T)`, the effects it may exercise — and the test-only
  `implement` providers controlling them — come from the `tool.use(T)` envelope.
  Nested `tool.call` pushes the nested envelope; returning pops it. This module
  is that stack plus the first step of per-effect resolution (the controlled
  `implement` provider); the remaining steps (replay → test-default → live →
  structured failure) stay in the effect modules and consume `provider/1`.

  ## Envelope shape

      %{
        tool: "Billing.Refund",
        # effect key => provider fun. Keys mirror capability kinds:
        #   "uuid", "instant", "http.out", "model", ...
        providers: %{"uuid" => (-> term())},
        # nested tool envelopes, keyed by tool name, pushed on nested tool.call.
        nested: %{"Other.Tool" => envelope}
      }

  The stack is process-scoped. Propagating it to spawned processes/tasks/timers
  is handled where work is spawned (a later #282 step); `snapshot/0` and
  `restore/1` exist for that hand-off.
  """

  @key {__MODULE__, :stack}

  @type provider :: (-> term()) | (term() -> term())
  @type envelope :: %{
          optional(:tool) => String.t(),
          optional(:providers) => %{optional(String.t()) => provider()},
          optional(:nested) => %{optional(String.t()) => envelope()}
        }

  @doc "Pushes a tool envelope onto the stack."
  @spec push(envelope()) :: :ok
  def push(envelope) when is_map(envelope) do
    Process.put(@key, [envelope | stack()])
    :ok
  end

  @doc "Pops the top envelope. Returns the popped envelope, or nil when empty."
  @spec pop() :: envelope() | nil
  def pop do
    case stack() do
      [] ->
        nil

      [top | rest] ->
        Process.put(@key, rest)
        top
    end
  end

  @doc "The active (innermost) tool envelope, or nil when none is active."
  @spec current() :: envelope() | nil
  def current, do: List.first(stack())

  @doc "Current stack depth."
  @spec depth() :: non_neg_integer()
  def depth, do: length(stack())

  @doc """
  Runs `fun` with `envelope` pushed, popping it afterward even on error. The
  stack is always restored to exactly its prior state.
  """
  @spec with_envelope(envelope(), (-> result)) :: result when result: term()
  def with_envelope(envelope, fun) when is_map(envelope) and is_function(fun, 0) do
    push(envelope)

    try do
      fun.()
    after
      pop()
    end
  end

  @doc """
  Resolves the controlled `implement` provider for `effect_key` from the active
  envelope. Returns `{:implement, provider}` when one is installed, or
  `:no_provider` so the caller falls through to replay → test-default → live →
  failure (the rest of the #282 resolution order).
  """
  @spec resolve(String.t()) :: {:implement, provider()} | :no_provider
  def resolve(effect_key) when is_binary(effect_key) do
    with %{} = envelope <- current(),
         providers when is_map(providers) <- Map.get(envelope, :providers, %{}),
         provider when not is_nil(provider) <- Map.get(providers, effect_key) do
      {:implement, provider}
    else
      _ -> :no_provider
    end
  end

  @doc "The nested envelope for `tool_name` under the active envelope, if any."
  @spec nested_envelope(String.t()) :: envelope() | nil
  def nested_envelope(tool_name) when is_binary(tool_name) do
    case current() do
      %{nested: nested} when is_map(nested) -> Map.get(nested, tool_name)
      _ -> nil
    end
  end

  @doc "Captures the current stack for hand-off to spawned work."
  @spec snapshot() :: [envelope()]
  def snapshot, do: stack()

  @doc "Installs a captured stack in the calling process (e.g. spawned work)."
  @spec restore([envelope()]) :: :ok
  def restore(captured) when is_list(captured) do
    Process.put(@key, captured)
    :ok
  end

  @doc "Clears the stack in the calling process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  defp stack, do: Process.get(@key, [])
end
