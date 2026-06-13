defmodule Skein.Runtime.StorePropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime Store module.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Store

  @caps [%{kind: "store.table", params: ["prop_test"]}]

  setup do
    Store.clear("prop_test")
    :ok
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp record_gen do
    gen all(
          id <- id_gen(),
          name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          age <- StreamData.integer(0..120)
        ) do
      %{id: id, name: name, age: age}
    end
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "put then get returns the same record" do
    check all(record <- record_gen()) do
      Store.clear("prop_test")
      {:ok, _} = Store.put("prop_test", record, @caps)
      assert {:ok, ^record} = Store.get("prop_test", record.id, @caps)
    end
  end

  property "put then delete then get returns not_found" do
    check all(record <- record_gen()) do
      Store.clear("prop_test")
      {:ok, _} = Store.put("prop_test", record, @caps)
      {:ok, _} = Store.delete("prop_test", record.id, @caps)
      assert {:error, "not_found"} = Store.get("prop_test", record.id, @caps)
    end
  end

  property "put overwrites previous record with same id" do
    check all(
            id <- id_gen(),
            name1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            name2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      Store.clear("prop_test")
      {:ok, _} = Store.put("prop_test", %{id: id, name: name1}, @caps)
      {:ok, _} = Store.put("prop_test", %{id: id, name: name2}, @caps)
      {:ok, record} = Store.get("prop_test", id, @caps)
      assert record.name == name2
    end
  end

  property "query with empty filters returns all records" do
    check all(records <- StreamData.list_of(record_gen(), min_length: 0, max_length: 5)) do
      Store.clear("prop_test")

      # Deduplicate by id (last wins)
      unique =
        records
        |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r.id, r) end)
        |> Map.values()

      Enum.each(unique, fn r -> Store.put("prop_test", r, @caps) end)

      {:ok, results} = Store.query("prop_test", %{}, @caps)
      assert length(results) == length(unique)
    end
  end

  property "operations on undeclared table always return error" do
    check all(id <- id_gen()) do
      empty_caps = []
      assert {:error, _} = Store.get("prop_test", id, empty_caps)
      assert {:error, _} = Store.put("prop_test", %{id: id}, empty_caps)
      assert {:error, _} = Store.delete("prop_test", id, empty_caps)
      assert {:error, _} = Store.query("prop_test", %{}, empty_caps)
    end
  end
end
