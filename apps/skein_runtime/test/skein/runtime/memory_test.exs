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
end
