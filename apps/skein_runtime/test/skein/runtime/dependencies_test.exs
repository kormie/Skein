defmodule Skein.Runtime.DependenciesTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Dependencies
  alias Skein.Runtime.Instant
  alias Skein.Runtime.Replay
  alias Skein.Runtime.Trace
  alias Skein.Runtime.Uuid

  @uuid_caps [%{kind: "uuid", params: []}]
  @instant_caps [%{kind: "instant", params: []}]

  setup do
    Trace.clear()
    :ok
  end

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

  describe "with_overrides — deterministic test values (swift-dependencies)" do
    test "incrementing uuid override is deterministic" do
      results =
        Dependencies.with_overrides([uuid: :incrementing], fn ->
          [Uuid.new(@uuid_caps), Uuid.new(@uuid_caps), Uuid.new(@uuid_caps)]
        end)

      assert results == [
               "00000000-0000-4000-8000-000000000000",
               "00000000-0000-4000-8000-000000000001",
               "00000000-0000-4000-8000-000000000002"
             ]
    end

    test "fixed instant override is deterministic" do
      now =
        Dependencies.with_overrides([instant: "2020-01-01T00:00:00Z"], fn ->
          Instant.now(@instant_caps)
        end)

      assert now == "2020-01-01T00:00:00Z"
    end

    test "a custom generator function works as an override" do
      value =
        Dependencies.with_overrides([uuid: fn -> "fixed-uuid" end], fn ->
          Uuid.new(@uuid_caps)
        end)

      assert value == "fixed-uuid"
    end

    test "overrides are restored after the block" do
      Dependencies.with_overrides([instant: "2020-01-01T00:00:00Z"], fn -> :ok end)
      # Outside the block the live clock is used again.
      assert Instant.now(@instant_caps) != "2020-01-01T00:00:00Z"
    end
  end

  describe "replay determinism" do
    test "a recorded uuid value is reproduced on replay" do
      trace = [%{"kind" => "uuid", "value" => "abc-123"}]

      replayed =
        Replay.with_replay(trace, fn ->
          Uuid.new(@uuid_caps)
        end)

      assert replayed == "abc-123"
    end

    test "a recorded instant value is reproduced on replay" do
      trace = [%{"kind" => "instant", "value" => "2021-06-15T00:00:00Z"}]

      replayed =
        Replay.with_replay(trace, fn ->
          Instant.now(@instant_caps)
        end)

      assert replayed == "2021-06-15T00:00:00Z"
    end
  end
end
