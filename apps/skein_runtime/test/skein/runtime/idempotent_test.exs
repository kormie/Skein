defmodule Skein.Runtime.IdempotentTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Idempotent

  setup do
    Idempotent.reset_all()
    :ok
  end

  describe "check!/1" do
    test "returns :ok for new key" do
      assert :ok = Idempotent.check!("new-key-1")
    end

    test "throws {:idempotent_skip} for duplicate key" do
      assert :ok = Idempotent.check!("dup-key")

      assert catch_throw(Idempotent.check!("dup-key")) == {:idempotent_skip}
    end

    test "different keys are independent" do
      assert :ok = Idempotent.check!("key-a")
      assert :ok = Idempotent.check!("key-b")
      assert :ok = Idempotent.check!("key-c")

      assert catch_throw(Idempotent.check!("key-a")) == {:idempotent_skip}
      assert catch_throw(Idempotent.check!("key-b")) == {:idempotent_skip}
    end
  end

  describe "processed?/1" do
    test "returns false for unseen key" do
      refute Idempotent.processed?("unseen")
    end

    test "returns true after check!" do
      Idempotent.check!("seen-key")
      assert Idempotent.processed?("seen-key")
    end
  end

  describe "clear/1" do
    test "allows reprocessing after clear" do
      Idempotent.check!("clear-me")
      assert Idempotent.processed?("clear-me")

      Idempotent.clear("clear-me")
      refute Idempotent.processed?("clear-me")

      # Should succeed again
      assert :ok = Idempotent.check!("clear-me")
    end
  end

  describe "reset_all/0" do
    test "clears all keys" do
      Idempotent.check!("r1")
      Idempotent.check!("r2")
      Idempotent.check!("r3")

      Idempotent.reset_all()

      refute Idempotent.processed?("r1")
      refute Idempotent.processed?("r2")
      refute Idempotent.processed?("r3")
    end
  end

  describe "TTL expiry" do
    test "expired keys are treated as new" do
      # Set a very short TTL for testing
      Application.put_env(:skein_runtime, :idempotent_ttl_ms, 1)

      Idempotent.check!("ttl-key")
      # Wait for expiry
      Process.sleep(5)

      # Should be treated as new
      assert :ok = Idempotent.check!("ttl-key")
    after
      Application.delete_env(:skein_runtime, :idempotent_ttl_ms)
    end
  end

  describe "sweep_expired/0" do
    test "removes expired keys" do
      Application.put_env(:skein_runtime, :idempotent_ttl_ms, 1)

      Idempotent.check!("sweep-1")
      Idempotent.check!("sweep-2")
      Process.sleep(5)

      removed = Idempotent.sweep_expired()
      assert removed >= 2
    after
      Application.delete_env(:skein_runtime, :idempotent_ttl_ms)
    end

    test "does not remove unexpired keys" do
      # Default TTL is 1 hour, so these won't expire
      Idempotent.check!("fresh-1")
      Idempotent.check!("fresh-2")

      removed = Idempotent.sweep_expired()
      assert removed == 0
      assert Idempotent.processed?("fresh-1")
    end
  end
end
