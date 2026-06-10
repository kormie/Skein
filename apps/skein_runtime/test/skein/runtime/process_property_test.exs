defmodule Skein.Runtime.ProcessPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Process, as: SpawnProcess

  setup do
    on_exit(fn -> SpawnProcess.reset_all() end)
  end

  property "spawning N processes always returns N unique pids" do
    check all(count <- integer(1..10)) do
      SpawnProcess.reset_all()
      Process.sleep(50)

      pids =
        for _ <- 1..count do
          {:ok, pid} =
            SpawnProcess.spawn(fn -> Process.sleep(2000) end, [
              %{kind: "process.spawn", params: []}
            ])

          pid
        end

      assert length(Enum.uniq(pids)) == count
    end
  end

  property "all spawned processes are alive immediately after spawn" do
    check all(count <- integer(1..5)) do
      SpawnProcess.reset_all()
      Process.sleep(50)

      pids =
        for _ <- 1..count do
          {:ok, pid} =
            SpawnProcess.spawn(fn -> Process.sleep(5000) end, [
              %{kind: "process.spawn", params: []}
            ])

          pid
        end

      # All pids should be alive right after spawn
      Enum.each(pids, fn pid ->
        assert Process.alive?(pid)
      end)
    end
  end

  property "spawn always returns {:ok, pid} for valid functions" do
    check all(_ <- integer(1..20)) do
      result = SpawnProcess.spawn(fn -> :ok end, [%{kind: "process.spawn", params: []}])
      assert {:ok, pid} = result
      assert is_pid(pid)
    end
  end
end
