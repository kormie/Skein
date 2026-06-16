defmodule Skein.Runtime.Dependencies do
  @moduledoc """
  Controlled nondeterministic dependencies — the `uuid.new()` / `instant.now()`
  effects (#261), inspired by [swift-dependencies](https://github.com/pointfreeco/swift-dependencies).

  These are the two pieces of ambient nondeterminism Skein controls so programs
  stay testable and replayable:

  - **Live** (production): a real v4 UUID / the wall clock.
  - **Overridden** (tests): a deterministic generator installed for the duration
    of `with_overrides/2` — e.g. incrementing UUIDs, a fixed/stepping instant —
    so a test gets reproducible values (swift-dependencies' `withDependencies`).
  - **Replayed**: when a recorded trace is active (`Skein.Runtime.Replay`), the
    recorded value is served and live values are recorded, so a trace that minted
    an id/timestamp reproduces exactly.

  Precedence: an explicit override wins; else a recorded value (replay); else a
  freshly generated live value (recorded for future replay).
  """

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.Replay
  alias Skein.Runtime.Stdlib
  alias Skein.Runtime.Trace

  @override_key {__MODULE__, :overrides}

  @doc """
  Runs `fun` with deterministic overrides installed for `:uuid` and/or
  `:instant`. Each override is either a zero-arity function returning the value,
  or a convenience preset:

    * `uuid: :incrementing` — `00000000-0000-4000-8000-0000000000NN`
    * `instant: "2020-01-01T00:00:00Z"` — that constant instant

  Overrides are scoped to the current process and restored afterward.
  """
  @spec with_overrides(keyword(), (-> term())) :: term()
  def with_overrides(opts, fun) when is_list(opts) and is_function(fun, 0) do
    previous = Process.get(@override_key)
    Process.put(@override_key, Map.new(opts, fn {k, v} -> {k, normalize_override(k, v)} end))

    try do
      fun.()
    after
      if previous, do: Process.put(@override_key, previous), else: Process.delete(@override_key)
    end
  end

  @doc "Produces a UUID through the override → replay → live precedence."
  @spec uuid() :: binary()
  def uuid, do: generate(:uuid)

  @doc "Produces an instant through the override → replay → live precedence."
  @spec instant() :: binary()
  def instant, do: generate(:instant)

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp generate(kind) do
    # Resolution order (#282): a scenario `implement` provider on the active
    # capability stack wins; then the legacy process-dict override; then replay;
    # then a live value.
    case CapabilityStack.resolve(Atom.to_string(kind)) do
      {:implement, provider} ->
        provider.()

      :no_provider ->
        case override(kind) do
          nil -> via_replay_or_live(kind)
          generator -> generator.()
        end
    end
  end

  defp override(kind) do
    Process.get(@override_key, %{}) |> Map.get(kind)
  end

  # Mirrors the Http recorded-span pattern: replay serves the recorded value;
  # otherwise generate live and record it on the span so the trace replays.
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
          value = live(kind)
          {value, %{value: value}}
      end
    end)
    |> unwrap_replay_result()
  end

  defp unwrap_replay_result({:replay_exhausted, kind}),
    do: raise(RuntimeError, "Replay trace exhausted: no recorded #{kind} value remains")

  defp unwrap_replay_result({:replay_mismatch, message}), do: raise(RuntimeError, message)
  defp unwrap_replay_result(value), do: value

  # Recorded events carry the value under :value / "value" (the extra meta the
  # live branch records).
  defp recorded_value(%{value: value}), do: value
  defp recorded_value(%{"value" => value}), do: value
  defp recorded_value(other), do: other

  defp live(:uuid), do: Stdlib.Uuid.new()
  defp live(:instant), do: Stdlib.Instant.now()

  defp normalize_override(_kind, generator) when is_function(generator, 0), do: generator

  defp normalize_override(:uuid, :incrementing) do
    counter_key = {__MODULE__, :uuid_counter}

    fn ->
      n = Process.get(counter_key, 0)
      Process.put(counter_key, n + 1)
      "00000000-0000-4000-8000-#{n |> Integer.to_string() |> String.pad_leading(12, "0")}"
    end
  end

  defp normalize_override(:instant, value) when is_binary(value), do: fn -> value end
end
