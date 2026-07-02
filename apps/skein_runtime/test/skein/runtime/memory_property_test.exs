defmodule Skein.Runtime.MemoryPropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime memory module.

  Tests KV operations across generated namespaces, keys, and values
  to ensure the memory store behaves correctly under wide inputs.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Memory
  alias Skein.Runtime.Trace

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp namespace_gen do
    gen all(
          name <-
            StreamData.string(Enum.to_list(?a..?z), min_length: 2, max_length: 12)
        ) do
      "prop_ns_#{name}"
    end
  end

  defp key_gen do
    StreamData.string(Enum.to_list(?a..?z) ++ [?_, ?:], min_length: 1, max_length: 20)
  end

  defp value_gen do
    StreamData.one_of([
      StreamData.string(:alphanumeric, min_length: 0, max_length: 50),
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.list_of(StreamData.integer(), min_length: 0, max_length: 5),
      StreamData.fixed_map(%{
        "name" => StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
        "count" => StreamData.integer(0..1000)
      })
    ])
  end

  defp caps_for(namespace) do
    [%{kind: "memory.kv", params: [namespace]}]
  end

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "put then get round-trips any value" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen(),
            value <- value_gen()
          ) do
      caps = caps_for(ns)
      assert {:ok, ^value} = Memory.put(ns, key, value, caps)
      assert {:ok, ^value} = Memory.get(ns, key, caps)
      Memory.clear(ns)
    end
  end

  property "get on missing key always returns not_found" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen()
          ) do
      Memory.clear(ns)
      caps = caps_for(ns)
      assert {:error, :not_found} = Memory.get(ns, key, caps)
    end
  end

  property "delete removes any previously stored key" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen(),
            value <- value_gen()
          ) do
      caps = caps_for(ns)
      Memory.put(ns, key, value, caps)
      assert {:ok, ^key} = Memory.delete(ns, key, caps)
      assert {:error, :not_found} = Memory.get(ns, key, caps)
      Memory.clear(ns)
    end
  end

  property "put overwrites previous value for same key" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen(),
            v1 <- StreamData.integer(),
            v2 <- StreamData.integer()
          ) do
      caps = caps_for(ns)
      Memory.put(ns, key, v1, caps)
      Memory.put(ns, key, v2, caps)
      assert {:ok, ^v2} = Memory.get(ns, key, caps)
      Memory.clear(ns)
    end
  end

  property "wildcard capability allows any namespace" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen(),
            value <- value_gen()
          ) do
      wildcard = [%{kind: "memory.kv", params: []}]
      assert {:ok, ^value} = Memory.put(ns, key, value, wildcard)
      assert {:ok, ^value} = Memory.get(ns, key, wildcard)
      Memory.clear(ns)
    end
  end

  property "operations with wrong namespace capability always fail" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen(),
            value <- value_gen()
          ) do
      wrong_caps = [%{kind: "memory.kv", params: ["definitely_wrong_namespace"]}]
      assert {:error, {:denied, msg}} = Memory.put(ns, key, value, wrong_caps)
      assert msg =~ ns
      Memory.clear(ns)
    end
  end

  property "operations with empty capabilities always fail" do
    check all(
            ns <- namespace_gen(),
            key <- key_gen()
          ) do
      Memory.clear(ns)
      assert {:error, {:denied, _}} = Memory.get(ns, key, [])
      assert {:error, {:denied, _}} = Memory.put(ns, key, "val", [])
      assert {:error, {:denied, _}} = Memory.delete(ns, key, [])
    end
  end

  property "list returns only keys matching prefix" do
    check all(
            ns <- namespace_gen(),
            prefix <- StreamData.string(Enum.to_list(?a..?z), min_length: 2, max_length: 5),
            suffixes <-
              StreamData.list_of(
                StreamData.string(Enum.to_list(?a..?z), min_length: 1, max_length: 5),
                min_length: 1,
                max_length: 5
              )
          ) do
      Memory.clear(ns)
      caps = caps_for(ns)

      # Store keys with the prefix
      for suffix <- suffixes do
        Memory.put(ns, "#{prefix}:#{suffix}", "val", caps)
      end

      # Store a key without the prefix
      Memory.put(ns, "other_key", "val", caps)

      keys = Memory.list(ns, "#{prefix}:", caps)
      assert Enum.all?(keys, &String.starts_with?(&1, "#{prefix}:"))
      refute "other_key" in keys

      Memory.clear(ns)
    end
  end

  property "namespaces are isolated from each other" do
    check all(
            ns1 <- namespace_gen(),
            ns2 <- namespace_gen(),
            ns1 != ns2,
            key <- key_gen(),
            v1 <- StreamData.integer(),
            v2 <- StreamData.integer(),
            v1 != v2
          ) do
      caps = [%{kind: "memory.kv", params: [ns1, ns2]}]
      Memory.put(ns1, key, v1, caps)
      Memory.put(ns2, key, v2, caps)

      assert {:ok, ^v1} = Memory.get(ns1, key, caps)
      assert {:ok, ^v2} = Memory.get(ns2, key, caps)

      Memory.clear(ns1)
      Memory.clear(ns2)
    end
  end
end
