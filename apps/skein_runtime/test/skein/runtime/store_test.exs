defmodule Skein.Runtime.StoreTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Store
  alias Skein.Runtime.Trace

  @caps [%{kind: "store.table", params: ["users"]}]

  setup do
    Store.clear("users")
    Store.clear("orders")
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # store.put
  # ------------------------------------------------------------------

  describe "put/3" do
    test "inserts a new record with atom :id key" do
      record = %{id: "u1", name: "Alice", email: "alice@example.com"}
      assert {:ok, ^record} = Store.put("users", record, @caps)
    end

    test "inserts a new record with string \"id\" key" do
      record = %{"id" => "u2", "name" => "Bob"}
      assert {:ok, ^record} = Store.put("users", record, @caps)
    end

    test "returns error when record has no id" do
      record = %{name: "NoId"}
      assert {:error, {:failed, msg}} = Store.put("users", record, @caps)
      assert msg =~ "id"
    end

    test "upserts (overwrites) existing record with same id" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alicia"}, @caps)

      {:ok, record} = Store.get("users", "u1", @caps)
      assert record.name == "Alicia"
    end

    test "returns capability error when table not declared" do
      result = Store.put("orders", %{id: "o1"}, @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.get
  # ------------------------------------------------------------------

  describe "get/3" do
    test "retrieves an existing record by id" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @caps)
      assert {:ok, %{id: "u1", name: "Alice"}} = Store.get("users", "u1", @caps)
    end

    test "returns not_found for missing id" do
      assert {:error, :not_found} = Store.get("users", "nonexistent", @caps)
    end

    test "returns capability error when table not declared" do
      result = Store.get("orders", "o1", @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.delete
  # ------------------------------------------------------------------

  describe "delete/3" do
    test "removes an existing record" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @caps)
      assert {:ok, "u1"} = Store.delete("users", "u1", @caps)
      assert {:error, :not_found} = Store.get("users", "u1", @caps)
    end

    test "deleting a non-existent id succeeds silently" do
      assert {:ok, "u999"} = Store.delete("users", "u999", @caps)
    end

    test "returns capability error when table not declared" do
      result = Store.delete("orders", "o1", @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # store.query
  # ------------------------------------------------------------------

  describe "query/3" do
    test "returns all records matching a single filter" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice", role: "admin"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u2", name: "Bob", role: "user"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u3", name: "Carol", role: "admin"}, @caps)

      {:ok, results} = Store.query("users", %{role: "admin"}, @caps)
      assert is_list(results)
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol"]
    end

    test "returns all records matching multiple filters" do
      {:ok, _} =
        Store.put("users", %{id: "u1", name: "Alice", role: "admin", active: true}, @caps)

      {:ok, _} = Store.put("users", %{id: "u2", name: "Bob", role: "admin", active: false}, @caps)
      {:ok, _} = Store.put("users", %{id: "u3", name: "Carol", role: "user", active: true}, @caps)

      {:ok, results} = Store.query("users", %{role: "admin", active: true}, @caps)
      assert length(results) == 1
      assert hd(results).name == "Alice"
    end

    test "returns empty list when no records match" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @caps)
      {:ok, results} = Store.query("users", %{name: "Nobody"}, @caps)
      assert results == []
    end

    test "returns all records with empty filters" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u2", name: "Bob"}, @caps)

      {:ok, results} = Store.query("users", %{}, @caps)
      assert length(results) == 2
    end

    test "returns capability error when table not declared" do
      result = Store.query("orders", %{}, @caps)
      assert {:error, {:denied, msg}} = result
      assert msg =~ "not declared"
    end

    test "returns an error for an unknown filter field" do
      # Regression: an unknown filter field used to silently return Ok([]),
      # so typos/bad columns masqueraded as "no results". It must now surface
      # as a matchable error so `!`/`?` fail loudly.
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice", role: "admin"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u2", name: "Bob", role: "user"}, @caps)

      assert {:error, {:failed, msg}} = Store.query("users", %{no_such_field: "x"}, @caps)
      assert msg =~ "Unknown filter field"
      assert msg =~ "no_such_field"
    end

    test "valid filters are unaffected by unknown-field validation" do
      {:ok, _} = Store.put("users", %{id: "u1", name: "Alice", role: "admin"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u2", name: "Bob", role: "user"}, @caps)

      assert {:ok, [%{name: "Alice"}]} = Store.query("users", %{role: "admin"}, @caps)
    end
  end

  # ------------------------------------------------------------------
  # Trace integration
  # ------------------------------------------------------------------

  describe "tracing" do
    test "put records a trace span" do
      Store.put("users", %{id: "u1", name: "Alice"}, @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :put
      assert span.table == "users"
      assert is_integer(span.duration_us)
      assert span.outcome == :ok
    end

    test "get records a trace span" do
      Store.get("users", "u1", @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :get
      assert span.table == "users"
    end

    test "delete records a trace span" do
      Store.delete("users", "u1", @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :delete
    end

    test "query records a trace span" do
      Store.query("users", %{}, @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :query
    end

    test "capability error still records a trace span" do
      Store.get("orders", "o1", @caps)

      spans = Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.outcome == :error
    end
  end

  # ------------------------------------------------------------------
  # Capability enforcement
  # ------------------------------------------------------------------

  describe "capability enforcement" do
    test "allows operations on declared tables" do
      assert {:ok, _} = Store.put("users", %{id: "u1"}, @caps)
      assert {:error, :not_found} = Store.get("users", "missing", @caps)
    end

    test "blocks operations on undeclared tables" do
      assert {:error, {:denied, msg}} = Store.get("orders", "o1", @caps)
      assert msg =~ "not declared"
    end

    test "empty capabilities block all store operations" do
      assert {:error, {:denied, msg}} = Store.get("users", "u1", [])
      assert msg =~ "not declared"
    end

    test "multiple table capabilities allow both tables" do
      multi_caps = [
        %{kind: "store.table", params: ["users"]},
        %{kind: "store.table", params: ["orders"]}
      ]

      Store.clear("orders")
      assert {:error, :not_found} = Store.get("users", "u1", multi_caps)
      assert {:error, :not_found} = Store.get("orders", "o1", multi_caps)
    end
  end

  # ------------------------------------------------------------------
  # clear/1
  # ------------------------------------------------------------------

  describe "clear/1" do
    test "removes all records from a table" do
      {:ok, _} = Store.put("users", %{id: "u1"}, @caps)
      {:ok, _} = Store.put("users", %{id: "u2"}, @caps)

      Store.clear("users")

      assert {:error, :not_found} = Store.get("users", "u1", @caps)
      assert {:error, :not_found} = Store.get("users", "u2", @caps)
    end
  end
end
