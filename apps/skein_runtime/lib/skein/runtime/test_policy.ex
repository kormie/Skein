defmodule Skein.Runtime.TestPolicy do
  @moduledoc """
  The conservative effect policy `skein test` installs around each scenario and
  golden test (#283, Wave 3).

  Production code (`skein run`) and the live runtime never install a policy, so
  effects resolve exactly as before: `implement → replay → live`. Under
  `skein test`, a policy context is active for the duration of each test, and the
  effect modules consult it as the **test-default** step between replay and live:

    1. **implement** — a scenario `implement` provider (`CapabilityStack`).
    2. **replay** — a golden trace (`Replay`).
    3. **test-default** *(this module)* — deterministic generators for `uuid` /
       `instant`; outbound effects (`http.out`, `model`) are **blocked** unless
       explicitly allowed.
    4. **live** — the real world, only when allowed.

  The policy is process-scoped (process dictionary), mirroring `CapabilityStack`
  and `Replay`. `snapshot/0` + `restore/1` hand it to spawned work.

  ## Live-effect allow-list

  `skein test --allow-live <effect>[:<scope>]` (repeatable) records exceptions to
  the block. An effect with no scope (`--allow-live model`) allows every scope;
  `--allow-live http.out:api.stripe.com` allows exactly that host. Only the
  outbound / nondeterministic effects are gatable:
  `#{inspect(["http.out", "model", "uuid", "instant"])}`. Isolated effects
  (`store`, `memory`, `event.log`) are never "live" — they get scenario-local
  state, not a block.
  """

  @key {__MODULE__, :policy}

  # The deterministic instant base; each call steps one second further.
  @instant_base ~U[2026-01-01 00:00:00Z]

  @gatable_effects ["http.out", "model", "uuid", "instant"]

  @type scope :: String.t() | :all
  @type allow_entry :: {String.t(), scope()}
  @type policy :: %{
          allow: %{optional(String.t()) => :all | MapSet.t(String.t())},
          uuid: non_neg_integer(),
          instant: non_neg_integer()
        }

  @doc """
  Runs `fun` with a fresh test policy installed, then removes it (even on error).

  Options:
  - `:allow_live` — a list of `{effect, scope | :all}` entries permitting live
    effects (parse user input with `parse_allow_live/1`).

  Deterministic `uuid`/`instant` counters start fresh, so two tests never share
  generated values.
  """
  @spec with_policy(keyword(), (-> result)) :: result when result: term()
  def with_policy(opts, fun) when is_list(opts) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, new_policy(opts))

    try do
      fun.()
    after
      restore_previous(previous)
    end
  end

  @doc "True when a test policy is active in the calling process."
  @spec active?() :: boolean()
  def active?, do: Process.get(@key) != nil

  @doc """
  True when the effect must be blocked from going live: a policy is active and
  the effect/scope is not on the allow-list. Outside a policy (production), this
  is always false.
  """
  @spec block_live?(String.t(), scope()) :: boolean()
  def block_live?(effect_key, scope \\ :all) when is_binary(effect_key) do
    case Process.get(@key) do
      nil -> false
      %{allow: allow} -> not allowed?(allow, effect_key, scope)
    end
  end

  @doc "Produces the next deterministic test UUID (`...-0000000000NN`, from 1)."
  @spec next_uuid() :: binary()
  def next_uuid do
    n = bump(:uuid)
    "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  end

  @doc "Produces the next deterministic test instant (fixed base, +1s per call)."
  @spec next_instant() :: binary()
  def next_instant do
    # bump/1 is 1-based; instant steps from the base (offset 0) on the first call.
    offset = bump(:instant) - 1
    @instant_base |> DateTime.add(offset, :second) |> DateTime.to_iso8601()
  end

  @doc "Captures the active policy for hand-off to spawned work."
  @spec snapshot() :: policy() | nil
  def snapshot, do: Process.get(@key)

  @doc "Installs a captured policy in the calling process (e.g. spawned work)."
  @spec restore(policy() | nil) :: :ok
  def restore(nil), do: clear()

  def restore(policy) when is_map(policy) do
    Process.put(@key, policy)
    :ok
  end

  @doc "Clears the policy in the calling process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "The effect tokens `--allow-live` accepts."
  @spec gatable_effects() :: [String.t()]
  def gatable_effects, do: @gatable_effects

  @doc """
  Parses one `--allow-live` argument (`<effect>[:<scope>]`) into an allow entry.

  Returns `{:ok, {effect, scope | :all}}` or `{:error, message}` for an unknown
  effect. The message names the offending token and the accepted effects.
  """
  @spec parse_allow_live(String.t()) :: {:ok, allow_entry()} | {:error, String.t()}
  def parse_allow_live(arg) when is_binary(arg) do
    {effect, scope} =
      case String.split(arg, ":", parts: 2) do
        [effect] -> {effect, :all}
        [effect, scope] -> {effect, scope}
      end

    cond do
      effect not in @gatable_effects ->
        {:error,
         "Unknown --allow-live effect '#{effect}'. " <>
           "Expected one of: #{Enum.join(@gatable_effects, ", ")}."}

      scope != :all and String.trim(scope) == "" ->
        {:error, "Empty scope in --allow-live '#{arg}'. Use '#{effect}' to allow all scopes."}

      true ->
        {:ok, {effect, scope}}
    end
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp new_policy(opts) do
    allow =
      opts
      |> Keyword.get(:allow_live, [])
      |> Enum.reduce(%{}, fn {effect, scope}, acc -> merge_allow(acc, effect, scope) end)

    %{allow: allow, uuid: 0, instant: 0}
  end

  # :all wins over any specific scopes; otherwise accumulate the scope set.
  defp merge_allow(acc, effect, :all), do: Map.put(acc, effect, :all)

  defp merge_allow(acc, effect, scope) do
    case Map.get(acc, effect) do
      :all -> acc
      nil -> Map.put(acc, effect, MapSet.new([scope]))
      %MapSet{} = set -> Map.put(acc, effect, MapSet.put(set, scope))
    end
  end

  defp allowed?(allow, effect_key, scope) do
    case Map.get(allow, effect_key) do
      :all -> true
      nil -> false
      %MapSet{} = set -> scope != :all and MapSet.member?(set, scope)
    end
  end

  defp bump(counter) do
    case Process.get(@key) do
      nil ->
        # Generators are only meaningful under a policy; default to 1/0 step so a
        # stray call is still deterministic rather than crashing.
        next(counter)

      policy ->
        n = Map.get(policy, counter, 0) + 1
        Process.put(@key, Map.put(policy, counter, n))
        n
    end
  end

  defp next(:uuid), do: 1
  defp next(:instant), do: 1

  defp restore_previous(nil), do: clear()
  defp restore_previous(policy), do: Process.put(@key, policy)
end
