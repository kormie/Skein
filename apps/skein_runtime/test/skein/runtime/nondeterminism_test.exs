defmodule Skein.Runtime.NondeterminismTest do
  @moduledoc """
  Resolution of the `uuid`/`instant` generator effects (#282): scenario
  `implement` provider (via the capability stack) → replay → live. The legacy
  `Skein.Runtime.Dependencies` / `with_overrides` is retired; deterministic test
  values now come from a pushed capability envelope.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.{CapabilityStack, Instant, Replay, Trace, Uuid}

  @uuid_caps [%{kind: "uuid", params: []}]
  @instant_caps [%{kind: "instant", params: []}]

  setup do
    Trace.clear()
    CapabilityStack.clear()
    on_exit(fn -> CapabilityStack.clear() end)
    :ok
  end

  # An incrementing uuid provider closure, mirroring the old `:incrementing`
  # override but installed through a capability envelope.
  defp incrementing_uuid do
    counter = :counters.new(1, [])

    fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      "00000000-0000-4000-8000-#{n |> Integer.to_string() |> String.pad_leading(12, "0")}"
    end
  end

  defp envelope(providers), do: %{tool: "T", providers: providers, nested: %{}}

  describe "capability enforcement" do
    test "uuid.new requires capability uuid" do
      assert_raise RuntimeError, fn -> Uuid.new([]) end
      uuid = Uuid.new(@uuid_caps)
      assert is_binary(uuid)
      assert String.length(uuid) == 36
    end

    test "instant.now requires capability instant" do
      assert_raise RuntimeError, fn -> Instant.now([]) end
      now = Instant.now(@instant_caps)
      assert is_binary(now)
      assert {:ok, _, _} = DateTime.from_iso8601(now)
    end
  end

  describe "implement providers — deterministic test values via a capability envelope" do
    test "an incrementing uuid provider is deterministic" do
      results =
        CapabilityStack.with_envelope(envelope(%{"uuid" => incrementing_uuid()}), fn ->
          [Uuid.new(@uuid_caps), Uuid.new(@uuid_caps), Uuid.new(@uuid_caps)]
        end)

      assert results == [
               "00000000-0000-4000-8000-000000000000",
               "00000000-0000-4000-8000-000000000001",
               "00000000-0000-4000-8000-000000000002"
             ]
    end

    test "a fixed instant provider is deterministic" do
      now =
        CapabilityStack.with_envelope(
          envelope(%{"instant" => fn -> "2020-01-01T00:00:00Z" end}),
          fn ->
            Instant.now(@instant_caps)
          end
        )

      assert now == "2020-01-01T00:00:00Z"
    end

    test "the provider is scoped to the envelope; the live clock returns afterward" do
      CapabilityStack.with_envelope(
        envelope(%{"instant" => fn -> "2020-01-01T00:00:00Z" end}),
        fn ->
          :ok
        end
      )

      assert Instant.now(@instant_caps) != "2020-01-01T00:00:00Z"
    end
  end

  describe "replay determinism" do
    test "a recorded uuid value is reproduced on replay" do
      trace = [%{"kind" => "uuid", "value" => "abc-123"}]
      assert Replay.with_replay(trace, fn -> Uuid.new(@uuid_caps) end) == "abc-123"
    end

    test "a recorded instant value is reproduced on replay" do
      trace = [%{"kind" => "instant", "value" => "2021-06-15T00:00:00Z"}]

      assert Replay.with_replay(trace, fn -> Instant.now(@instant_caps) end) ==
               "2021-06-15T00:00:00Z"
    end
  end

  describe "resolution order" do
    test "an implement provider wins over an active replay trace" do
      trace = [%{"kind" => "uuid", "value" => "from-replay"}]

      result =
        Replay.with_replay(trace, fn ->
          CapabilityStack.with_envelope(envelope(%{"uuid" => fn -> "from-provider" end}), fn ->
            Uuid.new(@uuid_caps)
          end)
        end)

      assert result == "from-provider"
    end
  end
end
