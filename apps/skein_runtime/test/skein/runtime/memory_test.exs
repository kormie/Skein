defmodule Skein.Runtime.MemoryTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Memory
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "memory.kv", params: ["sessions"]}]
  @wildcard_capabilities [%{kind: "memory.kv", params: []}]
  @wrong_capabilities [%{kind: "memory.kv", params: ["other_namespace"]}]
  @no_capabilities []

  setup do
    Memory.clear("sessions")
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # put/3
  # ------------------------------------------------------------------

  describe "put/3" do
    test "stores a value and returns {:ok, value}" do
      assert {:ok, "world"} = Memory.put("sessions", "hello", "world", @valid_capabilities)
    end

    test "overwrites existing values" do
      Memory.put("sessions", "key", "v1", @valid_capabilities)
      assert {:ok, "v2"} = Memory.put("sessions", "key", "v2", @valid_capabilities)
      assert {:ok, "v2"} = Memory.get("sessions", "key", @valid_capabilities)
    end

    test "stores complex values (maps, lists)" do
      value = %{name: "Alice", scores: [1, 2, 3]}
      assert {:ok, ^value} = Memory.put("sessions", "complex", value, @valid_capabilities)
      assert {:ok, ^value} = Memory.get("sessions", "complex", @valid_capabilities)
    end

    test "rejects without capability" do
      assert {:error, msg} = Memory.put("sessions", "key", "val", @no_capabilities)
      assert msg =~ "memory.kv"
    end

    test "rejects with wrong namespace capability" do
      assert {:error, msg} = Memory.put("sessions", "key", "val", @wrong_capabilities)
      assert msg =~ "sessions"
    end

    test "records a trace span" do
      Memory.put("sessions", "key", "val", @valid_capabilities)
      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :memory
      assert span.method == :put
      assert span.namespace == "sessions"
      assert span.outcome == :ok
    end
  end

  # ------------------------------------------------------------------
  # get/3
  # ------------------------------------------------------------------

  describe "get/3" do
    test "retrieves a stored value" do
      Memory.put("sessions", "hello", "world", @valid_capabilities)
      assert {:ok, "world"} = Memory.get("sessions", "hello", @valid_capabilities)
    end

    test "returns {:error, \"not_found\"} for missing keys" do
      assert {:error, "not_found"} = Memory.get("sessions", "nonexistent", @valid_capabilities)
    end

    test "rejects without capability" do
      assert {:error, msg} = Memory.get("sessions", "key", @no_capabilities)
      assert msg =~ "memory.kv"
    end

    test "records a trace span" do
      Memory.get("sessions", "key", @valid_capabilities)
      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :memory
      assert span.method == :get
    end
  end

  # ------------------------------------------------------------------
  # get!/3
  # ------------------------------------------------------------------

  describe "get!/3" do
    test "retrieves a stored value directly" do
      Memory.put("sessions", "hello", "world", @valid_capabilities)
      assert "world" = Memory.get!("sessions", "hello", @valid_capabilities)
    end

    test "raises on missing key" do
      assert_raise RuntimeError, ~r/not_found/, fn ->
        Memory.get!("sessions", "nonexistent", @valid_capabilities)
      end
    end

    test "raises on missing capability" do
      assert_raise RuntimeError, ~r/memory.kv/, fn ->
        Memory.get!("sessions", "key", @no_capabilities)
      end
    end
  end

  # ------------------------------------------------------------------
  # delete/3
  # ------------------------------------------------------------------

  describe "delete/3" do
    test "removes a stored value" do
      Memory.put("sessions", "hello", "world", @valid_capabilities)
      assert {:ok, "hello"} = Memory.delete("sessions", "hello", @valid_capabilities)
      assert {:error, "not_found"} = Memory.get("sessions", "hello", @valid_capabilities)
    end

    test "returns {:ok, key} even if key doesn't exist" do
      assert {:ok, "missing"} = Memory.delete("sessions", "missing", @valid_capabilities)
    end

    test "rejects without capability" do
      assert {:error, msg} = Memory.delete("sessions", "key", @no_capabilities)
      assert msg =~ "memory.kv"
    end

    test "records a trace span" do
      Memory.delete("sessions", "key", @valid_capabilities)
      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :memory
      assert span.method == :delete
    end
  end

  # ------------------------------------------------------------------
  # list/3
  # ------------------------------------------------------------------

  describe "list/3" do
    test "returns all keys with given prefix" do
      Memory.put("sessions", "user:1", "alice", @valid_capabilities)
      Memory.put("sessions", "user:2", "bob", @valid_capabilities)
      Memory.put("sessions", "config:theme", "dark", @valid_capabilities)

      keys = Memory.list("sessions", "user:", @valid_capabilities)
      assert Enum.sort(keys) == ["user:1", "user:2"]
    end

    test "returns all keys with empty prefix" do
      Memory.put("sessions", "a", 1, @valid_capabilities)
      Memory.put("sessions", "b", 2, @valid_capabilities)

      keys = Memory.list("sessions", "", @valid_capabilities)
      assert length(keys) == 2
      assert "a" in keys
      assert "b" in keys
    end

    test "returns empty list when no keys match" do
      assert [] = Memory.list("sessions", "nonexistent:", @valid_capabilities)
    end

    test "rejects without capability" do
      assert {:error, msg} = Memory.list("sessions", "", @no_capabilities)
      assert msg =~ "memory.kv"
    end
  end

  # ------------------------------------------------------------------
  # Wildcard capabilities
  # ------------------------------------------------------------------

  describe "wildcard capabilities" do
    test "allows any namespace with empty params" do
      assert {:ok, "val"} = Memory.put("any_ns", "key", "val", @wildcard_capabilities)
      assert {:ok, "val"} = Memory.get("any_ns", "key", @wildcard_capabilities)
    end
  end

  # ------------------------------------------------------------------
  # Namespace isolation
  # ------------------------------------------------------------------

  describe "namespace isolation" do
    test "different namespaces don't share data" do
      caps = [%{kind: "memory.kv", params: ["ns1", "ns2"]}]
      Memory.put("ns1", "key", "value1", caps)
      Memory.put("ns2", "key", "value2", caps)

      assert {:ok, "value1"} = Memory.get("ns1", "key", caps)
      assert {:ok, "value2"} = Memory.get("ns2", "key", caps)

      Memory.clear("ns1")
      Memory.clear("ns2")
    end
  end

  # ------------------------------------------------------------------
  # Instance-scoped memory (agent context)
  # ------------------------------------------------------------------

  describe "agent instance-scoped memory" do
    @caps [%{kind: "memory.kv", params: ["sessions"]}]

    test "keys are scoped per agent instance" do
      # Simulate two agent instances writing to the same namespace and key
      Memory.clear("sessions")

      # Agent instance 1
      Process.put(:skein_agent_name, "RefundAgent")
      Process.put(:skein_agent_instance_id, "inst_aaa")

      Memory.put("sessions", "decision", "approve", @caps)

      # Agent instance 2
      Process.put(:skein_agent_name, "RefundAgent")
      Process.put(:skein_agent_instance_id, "inst_bbb")

      Memory.put("sessions", "decision", "reject", @caps)

      # Instance 2 sees its own value
      assert {:ok, "reject"} = Memory.get("sessions", "decision", @caps)

      # Switch back to instance 1
      Process.put(:skein_agent_instance_id, "inst_aaa")
      assert {:ok, "approve"} = Memory.get("sessions", "decision", @caps)

      Memory.clear("sessions")
    end

    test "memory.list returns only current instance's keys" do
      Memory.clear("sessions")

      Process.put(:skein_agent_name, "TestAgent")
      Process.put(:skein_agent_instance_id, "inst_111")
      Memory.put("sessions", "key_a", "val_a", @caps)

      Process.put(:skein_agent_instance_id, "inst_222")
      Memory.put("sessions", "key_b", "val_b", @caps)

      # Instance 222 should only see key_b
      keys = Memory.list("sessions", "", @caps)
      assert keys == ["key_b"]

      # Instance 111 should only see key_a
      Process.put(:skein_agent_instance_id, "inst_111")
      keys = Memory.list("sessions", "", @caps)
      assert keys == ["key_a"]

      Memory.clear("sessions")
    end

    test "delete only affects current instance's key" do
      Memory.clear("sessions")

      Process.put(:skein_agent_name, "DelAgent")
      Process.put(:skein_agent_instance_id, "inst_del1")
      Memory.put("sessions", "shared_key", "val1", @caps)

      Process.put(:skein_agent_instance_id, "inst_del2")
      Memory.put("sessions", "shared_key", "val2", @caps)
      Memory.delete("sessions", "shared_key", @caps)

      # Instance del2's key is gone
      assert {:error, "not_found"} = Memory.get("sessions", "shared_key", @caps)

      # Instance del1's key is intact
      Process.put(:skein_agent_instance_id, "inst_del1")
      assert {:ok, "val1"} = Memory.get("sessions", "shared_key", @caps)

      Memory.clear("sessions")
    end

    test "no agent context means no scoping (backward compatible)" do
      Memory.clear("sessions")
      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)

      Memory.put("sessions", "plain_key", "plain_val", @caps)
      assert {:ok, "plain_val"} = Memory.get("sessions", "plain_key", @caps)

      Memory.clear("sessions")
    end

    test "capability enforcement still applies with instance scoping" do
      Process.put(:skein_agent_name, "CapAgent")
      Process.put(:skein_agent_instance_id, "inst_cap1")

      no_caps = []
      assert {:error, _} = Memory.put("sessions", "key", "val", no_caps)

      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)
    end

    test "special characters in keys work correctly" do
      Memory.clear("sessions")
      Process.put(:skein_agent_name, "SpecAgent")
      Process.put(:skein_agent_instance_id, "inst_spec")

      assert {:ok, _} = Memory.put("sessions", "key:with:colons", "val1", @caps)
      assert {:ok, _} = Memory.put("sessions", "key/with/slashes", "val2", @caps)
      assert {:ok, _} = Memory.put("sessions", "", "empty_key", @caps)

      assert {:ok, "val1"} = Memory.get("sessions", "key:with:colons", @caps)
      assert {:ok, "val2"} = Memory.get("sessions", "key/with/slashes", @caps)
      assert {:ok, "empty_key"} = Memory.get("sessions", "", @caps)

      Memory.clear("sessions")
      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)
    end

    test "large values are stored and retrieved" do
      Memory.clear("sessions")
      Process.put(:skein_agent_name, "LargeAgent")
      Process.put(:skein_agent_instance_id, "inst_large")

      large_value = String.duplicate("x", 100_000)
      assert {:ok, ^large_value} = Memory.put("sessions", "big", large_value, @caps)
      assert {:ok, ^large_value} = Memory.get("sessions", "big", @caps)

      Memory.clear("sessions")
      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)
    end

    test "concurrent instances via spawned tasks are isolated" do
      Memory.clear("sessions")
      caps = @caps

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Process.put(:skein_agent_name, "ConcAgent")
            Process.put(:skein_agent_instance_id, "inst_#{i}")
            Memory.put("sessions", "key", "val_#{i}", caps)
            Memory.get("sessions", "key", caps)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for i <- 1..5 do
        assert Enum.at(results, i - 1) == {:ok, "val_#{i}"}
      end

      Memory.clear("sessions")
    end

    test "list with prefix filter in scoped context" do
      Memory.clear("sessions")
      Process.put(:skein_agent_name, "PrefAgent")
      Process.put(:skein_agent_instance_id, "inst_pref")

      Memory.put("sessions", "user:1", "a", @caps)
      Memory.put("sessions", "user:2", "b", @caps)
      Memory.put("sessions", "config:x", "c", @caps)

      keys = Memory.list("sessions", "user:", @caps)
      assert Enum.sort(keys) == ["user:1", "user:2"]

      Memory.clear("sessions")
      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)
    end

    test "clearing namespace removes all instances' data" do
      Process.put(:skein_agent_name, "ClearAgent")
      Process.put(:skein_agent_instance_id, "inst_c1")
      Memory.put("sessions", "k", "v1", @caps)

      Process.put(:skein_agent_instance_id, "inst_c2")
      Memory.put("sessions", "k", "v2", @caps)

      Memory.clear("sessions")

      Process.put(:skein_agent_instance_id, "inst_c1")
      assert {:error, "not_found"} = Memory.get("sessions", "k", @caps)

      Process.put(:skein_agent_instance_id, "inst_c2")
      assert {:error, "not_found"} = Memory.get("sessions", "k", @caps)

      Process.delete(:skein_agent_name)
      Process.delete(:skein_agent_instance_id)
    end
  end
end
