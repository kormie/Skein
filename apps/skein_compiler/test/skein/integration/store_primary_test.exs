defmodule Skein.Integration.StorePrimaryTest do
  # Compiled modules share the global ETS store — never async.
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end contract for typed store tables with a non-`id` primary
  (#340): the spec (§3.2/§6.2, E0043) allows any single `@primary` field,
  so a compiled `put` must key the row by THAT field — the runtime key
  extraction was hard-coded to `id`, making `sku: String @primary`
  compile clean and fail at runtime.
  """

  setup do
    Skein.Runtime.Store.clear("items")
    :ok
  end

  test "a sku-primary table round-trips put -> get -> delete" do
    {:module, mod} =
      Skein.Compiler.compile_string("""
      module Inventory {
        capability store.table("items", Item)

        type Item { sku: String @primary, qty: Int }

        fn restock(sku: String, qty: Int) -> Result[Item, StoreError] {
          store.items.put(Item { sku: sku, qty: qty })
        }

        fn lookup_qty(sku: String) -> Int {
          match store.items.get(sku) {
            Ok(item)  -> item.qty
            Err(_)    -> 0
          }
        }

        fn remove(sku: String) -> Result[String, StoreError] {
          store.items.delete(sku)
        }
      }
      """)

    assert {:ok, %{sku: "SKU-9", qty: 4}} = mod.restock("SKU-9", 4)
    assert mod.lookup_qty("SKU-9") == 4
    assert {:ok, "SKU-9"} = mod.remove("SKU-9")
    assert mod.lookup_qty("SKU-9") == 0
  end

  test "an id-primary table keeps working identically" do
    {:module, mod} =
      Skein.Compiler.compile_string("""
      module Users {
        capability store.table("items", User)

        type User { id: String @primary, name: String }

        fn save(id: String, name: String) -> Result[User, StoreError] {
          store.items.put(User { id: id, name: name })
        }

        fn find(id: String) -> Result[User, StoreError] {
          store.items.get(id)
        }
      }
      """)

    assert {:ok, %{id: "u1", name: "Ada"}} = mod.save("u1", "Ada")
    assert {:ok, %{id: "u1", name: "Ada"}} = mod.find("u1")
  end
end
