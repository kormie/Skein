defmodule Skein.Runtime.EtsTablesTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.EtsTables

  test "a table created via ensure_table survives the creating process" do
    table = :ets_tables_test_survival

    task =
      Task.async(fn ->
        EtsTables.ensure_table(table, [:named_table, :set, :public])
        :ets.insert(table, {:k, 1})
      end)

    Task.await(task)
    ref = Process.monitor(task.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1000

    # The creating process is dead; the table must still be alive.
    assert :ets.whereis(table) != :undefined
    assert [{:k, 1}] = :ets.lookup(table, :k)

    :ets.delete(table)
  end

  test "ensure_table is idempotent" do
    table = :ets_tables_test_idempotent

    assert :ok = EtsTables.ensure_table(table, [:named_table, :set, :public])
    :ets.insert(table, {:k, :kept})
    assert :ok = EtsTables.ensure_table(table, [:named_table, :set, :public])

    # A second ensure must not recreate (and so wipe) the table.
    assert [{:k, :kept}] = :ets.lookup(table, :k)

    :ets.delete(table)
  end

  test "concurrent callers all succeed and the table exists once" do
    table = :ets_tables_test_concurrent

    results =
      1..50
      |> Enum.map(fn _ ->
        Task.async(fn -> EtsTables.ensure_table(table, [:named_table, :set, :public]) end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &(&1 == :ok))
    assert :ets.whereis(table) != :undefined

    :ets.delete(table)
  end

  test "the owner is supervised by the runtime application" do
    children = Supervisor.which_children(SkeinRuntime.Supervisor)

    assert Enum.any?(children, fn {id, _pid, _type, _modules} -> id == EtsTables end)
  end
end
