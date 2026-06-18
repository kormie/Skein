defmodule Skein.Runtime.SpawnContext do
  @moduledoc """
  Propagation of the scenario capability context across spawn boundaries (#282).

  The dynamic scenario capability stack (`Skein.Runtime.CapabilityStack`) and the
  `skein test` effect policy (`Skein.Runtime.TestPolicy`) are **process-scoped**:
  both live in the process dictionary so production effects resolve exactly as
  before and tests stay isolated. The process dictionary does **not** cross a
  process boundary, so work the runtime spawns in a fresh process — a
  `process.spawn` body, a `timer` task body — would otherwise lose the context
  and silently fall back to live/default resolution.

  `bind/1` closes that gap. It captures the spawning (or, for timers, the
  scheduling) process's context *now*, while that process is still on the stack,
  and returns a zero-arity function that reinstalls the captured context inside
  the spawned process before running the original work. The capture must happen
  in the originating process; the restore happens in the spawned one.

  Three things travel together so spawned work resolves effects identically to
  inline work:

    * the **capability stack** — the active `tool.use(T)` envelope chain, so a
      scenario `implement` provider that is in effect when work is spawned still
      wins inside the body;
    * the **registered scenario envelopes** — so a *top-level* `tool.call` made
      from spawned work still resolves its envelope; and
    * the **test policy** — so blocked-live (`http.out`/`model`) stays blocked and
      `uuid`/`instant` stay deterministic inside the body.

  In production no envelope is registered and no policy is active, so the captured
  context is empty and the restore is a transparent no-op — spawned work behaves
  exactly as it did before. The deterministic `uuid`/`instant` counters are copied
  by value (there is no shared counter across processes), so each spawned body
  continues its own deterministic sequence from the captured point.

  `Skein.Runtime.Replay` is intentionally **not** propagated: its recorded-event
  cursor is consumed (mutated) on every read, so handing a copy to a concurrent
  task would double-serve events. Golden replay across spawned work is a separate
  concern tracked beyond #282.
  """

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.TestPolicy

  @doc """
  Captures the calling process's scenario capability context and wraps `fun` so
  that the context is reinstalled before `fun` runs in the spawned process.

  Call this in the process that owns the context (the one performing the
  `process.spawn`, or scheduling the `timer`), then run the returned function in
  the spawned process.
  """
  @spec bind((-> result)) :: (-> result) when result: var
  def bind(fun) when is_function(fun, 0) do
    stack = CapabilityStack.snapshot()
    registry = CapabilityStack.snapshot_registry()
    policy = TestPolicy.snapshot()

    fn ->
      CapabilityStack.restore(stack)
      CapabilityStack.restore_registry(registry)
      TestPolicy.restore(policy)
      fun.()
    end
  end
end
