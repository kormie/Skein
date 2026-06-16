defmodule Skein.Runtime.TestPolicyTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.TestPolicy

  setup do
    on_exit(fn -> TestPolicy.clear() end)
    :ok
  end

  describe "active?/0" do
    test "is false outside a policy context" do
      refute TestPolicy.active?()
    end

    test "is true inside with_policy/2 and false again afterward" do
      TestPolicy.with_policy([], fn -> assert TestPolicy.active?() end)
      refute TestPolicy.active?()
    end

    test "is restored to false even when the body raises" do
      assert_raise RuntimeError, fn ->
        TestPolicy.with_policy([], fn -> raise "boom" end)
      end

      refute TestPolicy.active?()
    end
  end

  describe "block_live?/2" do
    test "never blocks outside a policy context (production)" do
      refute TestPolicy.block_live?("http.out", "api.stripe.com")
      refute TestPolicy.block_live?("model", "claude")
    end

    test "blocks an effect with no allow entry inside a policy" do
      TestPolicy.with_policy([], fn ->
        assert TestPolicy.block_live?("http.out", "api.stripe.com")
        assert TestPolicy.block_live?("model", "claude")
      end)
    end

    test "an exact scope allow permits only that scope" do
      TestPolicy.with_policy([allow_live: [{"http.out", "api.stripe.com"}]], fn ->
        refute TestPolicy.block_live?("http.out", "api.stripe.com")
        assert TestPolicy.block_live?("http.out", "evil.example.com")
      end)
    end

    test "a scopeless allow (:all) permits every scope of that effect" do
      TestPolicy.with_policy([allow_live: [{"http.out", :all}]], fn ->
        refute TestPolicy.block_live?("http.out", "api.stripe.com")
        refute TestPolicy.block_live?("http.out", "anything.example.com")
      end)
    end

    test "an allow for one effect does not leak to another" do
      TestPolicy.with_policy([allow_live: [{"http.out", :all}]], fn ->
        assert TestPolicy.block_live?("model", "claude")
      end)
    end
  end

  describe "deterministic uuid provider" do
    test "increments from 1 and is valid v4-shaped" do
      TestPolicy.with_policy([], fn ->
        assert TestPolicy.next_uuid() == "00000000-0000-4000-8000-000000000001"
        assert TestPolicy.next_uuid() == "00000000-0000-4000-8000-000000000002"
        assert {:ok, _} = Skein.Runtime.Stdlib.Uuid.parse(TestPolicy.next_uuid())
      end)
    end

    test "resets between policy contexts" do
      TestPolicy.with_policy([], fn ->
        assert TestPolicy.next_uuid() == "00000000-0000-4000-8000-000000000001"
      end)

      TestPolicy.with_policy([], fn ->
        assert TestPolicy.next_uuid() == "00000000-0000-4000-8000-000000000001"
      end)
    end
  end

  describe "deterministic instant provider" do
    test "starts at the fixed base and steps one second per call" do
      TestPolicy.with_policy([], fn ->
        assert TestPolicy.next_instant() == "2026-01-01T00:00:00Z"
        assert TestPolicy.next_instant() == "2026-01-01T00:00:01Z"
        assert TestPolicy.next_instant() == "2026-01-01T00:00:02Z"
      end)
    end
  end

  describe "parse_allow_live/1" do
    test "parses an effect with a scope" do
      assert {:ok, {"http.out", "api.stripe.com"}} =
               TestPolicy.parse_allow_live("http.out:api.stripe.com")
    end

    test "parses a scopeless effect as :all" do
      assert {:ok, {"model", :all}} = TestPolicy.parse_allow_live("model")
    end

    test "rejects an unknown effect with a structured error" do
      assert {:error, message} = TestPolicy.parse_allow_live("store.table:users")
      assert message =~ "store.table"
      assert message =~ "http.out"
    end
  end

  describe "snapshot/restore" do
    test "carries the active policy to another process" do
      TestPolicy.with_policy([allow_live: [{"http.out", :all}]], fn ->
        snapshot = TestPolicy.snapshot()

        task =
          Task.async(fn ->
            TestPolicy.restore(snapshot)
            {TestPolicy.active?(), TestPolicy.block_live?("http.out", "x")}
          end)

        assert Task.await(task) == {true, false}
      end)
    end
  end
end
