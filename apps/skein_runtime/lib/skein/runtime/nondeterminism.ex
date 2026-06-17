defmodule Skein.Runtime.Nondeterminism do
  @moduledoc """
  Resolution of nondeterministic generator effects — `uuid.new()` and
  `instant.now()` (#261, #282).

  These are capability-gated effects, not ambient stdlib, so their values are
  controlled. Resolution order:

    1. **implement** — a scenario `implement` provider on the active capability
       stack (`Skein.Runtime.CapabilityStack`) wins.
    2. **replay** — under an active recorded trace, the recorded value is served
       (and live values are recorded so a trace reproduces exactly).
    3. **test-default** — under `skein test` (`Skein.Runtime.TestPolicy` active),
       a deterministic generator (incrementing UUID / stepping instant), unless
       the run opted into live values with `--allow-live`.
    4. **live** — a real v4 UUID / the wall clock, in production.

  (The legacy process-dictionary override and `Skein.Runtime.Dependencies` are
  retired; deterministic values under test now come from scenario envelopes or
  the test-runner default policy.)
  """

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.Replay
  alias Skein.Runtime.Stdlib
  alias Skein.Runtime.TestPolicy
  alias Skein.Runtime.Trace

  @doc "Produces a UUID through the implement → replay → live order."
  @spec uuid() :: binary()
  def uuid, do: generate(:uuid)

  @doc "Produces an instant through the implement → replay → live order."
  @spec instant() :: binary()
  def instant, do: generate(:instant)

  defp generate(kind) do
    case CapabilityStack.resolve(Atom.to_string(kind)) do
      {:implement, provider} -> provider.()
      :no_provider -> via_replay_or_live(kind)
    end
  end

  # Replay serves the recorded value; otherwise a live value is generated and
  # recorded on the span so the trace replays.
  defp via_replay_or_live(kind) do
    Trace.with_recorded_span(%{kind: kind}, fn ->
      case Replay.next_response(kind) do
        {:ok, recorded} ->
          {recorded_value(recorded), %{replayed: true}}

        :exhausted ->
          {{:replay_exhausted, kind}, %{replayed: true}}

        {:mismatch, message} ->
          {{:replay_mismatch, message}, %{replayed: true}}

        :no_replay ->
          value = test_default_or_live(kind)
          {value, %{value: value}}
      end
    end)
    |> unwrap_replay_result()
  end

  # Under `skein test`, an unimplemented/unrecorded generator gets a deterministic
  # value unless the run allowed live values for it; in production it is live.
  defp test_default_or_live(kind) do
    if TestPolicy.block_live?(Atom.to_string(kind)) do
      deterministic(kind)
    else
      live(kind)
    end
  end

  defp deterministic(:uuid), do: TestPolicy.next_uuid()
  defp deterministic(:instant), do: TestPolicy.next_instant()

  defp unwrap_replay_result({:replay_exhausted, kind}),
    do: raise(RuntimeError, "Replay trace exhausted: no recorded #{kind} value remains")

  defp unwrap_replay_result({:replay_mismatch, message}), do: raise(RuntimeError, message)
  defp unwrap_replay_result(value), do: value

  # Recorded events carry the value under :value / "value".
  defp recorded_value(%{value: value}), do: value
  defp recorded_value(%{"value" => value}), do: value
  defp recorded_value(other), do: other

  defp live(:uuid), do: Stdlib.Uuid.new()
  defp live(:instant), do: Stdlib.Instant.now()
end
