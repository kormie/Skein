defmodule Skein.Runtime.SpawnContextTest do
  @moduledoc """
  Tests for scenario capability-context propagation across spawn boundaries
  (#282). The context lives in the process dictionary, which does not cross a
  process boundary, so these tests run the bound function in a *fresh* process
  (`Task.async/1`) and assert it observes the originating process's context.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.SpawnContext
  alias Skein.Runtime.TestPolicy

  setup do
    CapabilityStack.clear()
    TestPolicy.clear()

    on_exit(fn ->
      CapabilityStack.clear()
      TestPolicy.clear()
    end)

    :ok
  end

  # Runs `fun` in a fresh, unrelated process and returns its result.
  defp in_fresh_process(fun), do: fun |> Task.async() |> Task.await(1000)

  defp resolve_uuid do
    case CapabilityStack.resolve("uuid") do
      {:implement, provider} -> provider.()
      :no_provider -> :no_provider
    end
  end

  describe "bind/1 — capability stack" do
    test "reinstalls the active envelope's implement provider in a spawned process" do
      envelope = %{tool: "Billing.Refund", providers: %{"uuid" => fn -> "FROM-ENVELOPE" end}}

      bound =
        CapabilityStack.with_envelope(envelope, fn ->
          SpawnContext.bind(&resolve_uuid/0)
        end)

      # The envelope was popped when with_envelope returned; the stack is not
      # ambient, so neither this process nor a bare fresh process sees it.
      assert resolve_uuid() == :no_provider
      assert in_fresh_process(&resolve_uuid/0) == :no_provider

      # The bound body, however, carries the captured envelope into the task.
      assert in_fresh_process(bound) == "FROM-ENVELOPE"
    end
  end

  describe "bind/1 — test policy" do
    test "reinstalls the blocked-live policy in a spawned process" do
      observe = fn ->
        {TestPolicy.active?(), TestPolicy.block_live?("http.out", "api.stripe.com")}
      end

      bound = TestPolicy.with_policy([], fn -> SpawnContext.bind(observe) end)

      # A bare fresh process has no policy: nothing is active and nothing blocked.
      assert in_fresh_process(observe) == {false, false}

      # The bound body inherits the policy, so live http.out stays blocked.
      assert in_fresh_process(bound) == {true, true}
    end

    test "carries an --allow-live exception into the spawned process" do
      observe = fn -> TestPolicy.block_live?("http.out", "api.stripe.com") end

      bound =
        TestPolicy.with_policy([allow_live: [{"http.out", "api.stripe.com"}]], fn ->
          SpawnContext.bind(observe)
        end)

      assert in_fresh_process(bound) == false
    end
  end

  describe "bind/1 — registered scenario envelopes" do
    test "reinstalls the registry so a top-level tool.call resolves from spawned work" do
      envelope = %{tool: "Billing.Refund", providers: %{}}
      CapabilityStack.register_envelopes(%{"Billing.Refund" => envelope})

      bound = SpawnContext.bind(fn -> CapabilityStack.registered_envelope("Billing.Refund") end)

      # The registry is process-scoped, so a bare fresh process starts empty.
      assert in_fresh_process(fn -> CapabilityStack.registered_envelope("Billing.Refund") end) ==
               nil

      assert in_fresh_process(bound) == envelope
    end
  end

  describe "bind/1 — production (no context)" do
    test "is a transparent no-op when no envelope or policy is active" do
      bound =
        SpawnContext.bind(fn ->
          {CapabilityStack.snapshot(), CapabilityStack.snapshot_registry(), TestPolicy.snapshot()}
        end)

      assert in_fresh_process(bound) == {[], %{}, nil}
    end

    test "still runs the wrapped work and returns its result" do
      assert in_fresh_process(SpawnContext.bind(fn -> 1 + 2 end)) == 3
    end
  end

  property "spawned work observes the parent's envelope provider and test policy" do
    check all(
            value <- string(:alphanumeric, min_length: 1),
            allow_http? <- boolean(),
            max_runs: 50
          ) do
      CapabilityStack.clear()
      TestPolicy.clear()

      observe = fn ->
        {resolve_uuid(), TestPolicy.active?(), TestPolicy.block_live?("http.out", "h")}
      end

      allow = if allow_http?, do: [allow_live: [{"http.out", :all}]], else: []
      envelope = %{providers: %{"uuid" => fn -> value end}}

      {bound, expected} =
        CapabilityStack.with_envelope(envelope, fn ->
          TestPolicy.with_policy(allow, fn -> {SpawnContext.bind(observe), observe.()} end)
        end)

      # The captured context resolves the provider value, reports the policy as
      # active, and blocks live http.out unless it was explicitly allowed.
      assert expected == {value, true, not allow_http?}
      # The spawned body observes exactly the same — propagation is faithful.
      assert in_fresh_process(bound) == expected
    end
  end
end
