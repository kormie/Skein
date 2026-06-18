defmodule Skein.Runtime.ProcessTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.Process, as: SpawnProcess
  alias Skein.Runtime.TestPolicy

  setup do
    on_exit(fn ->
      SpawnProcess.reset_all()
      CapabilityStack.clear()
      TestPolicy.clear()
    end)
  end

  describe "spawn/3 with a pool and task name (compiled process.spawn(\"name\") calls)" do
    test "spawns when the pool matches the declared label" do
      assert {:ok, pid} =
               SpawnProcess.spawn("workers", "image-resize", [
                 %{kind: "process.spawn", params: ["workers"]}
               ])

      assert is_pid(pid)
    end

    test "blocks a pool outside the declared label" do
      assert {:error, message} =
               SpawnProcess.spawn("reports", "image-resize", [
                 %{kind: "process.spawn", params: ["workers"]}
               ])

      assert message =~ "reports"
      assert message =~ "workers"
    end

    test "unscoped declaration permits any pool" do
      assert {:ok, pid} =
               SpawnProcess.spawn("anything", "image-resize", [
                 %{kind: "process.spawn", params: []}
               ])

      assert is_pid(pid)
    end

    test "nil pool with an unscoped declaration is permitted" do
      assert {:ok, pid} =
               SpawnProcess.spawn(nil, "image-resize", [%{kind: "process.spawn", params: []}])

      assert is_pid(pid)
    end

    test "nil pool with a scoped declaration is blocked" do
      assert {:error, message} =
               SpawnProcess.spawn(nil, "image-resize", [
                 %{kind: "process.spawn", params: ["workers"]}
               ])

      assert message =~ "workers"
    end

    test "task name without capability is blocked" do
      assert {:error, message} = SpawnProcess.spawn("workers", "image-resize", [])
      assert message =~ "process.spawn"
    end

    test "records the pool on the trace span" do
      Skein.Runtime.Trace.init()

      {:ok, _pid} =
        SpawnProcess.spawn("workers", "image-resize", [
          %{kind: "process.spawn", params: ["workers"]}
        ])

      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1[:kind] == :process and &1[:task] == "image-resize"))

      assert span
      assert span[:pool] == "workers"
    end
  end

  describe "spawn/4 with a task body (compiled process.spawn(\"name\", &fn) calls)" do
    test "executes the function in the background" do
      test_pid = self()

      assert {:ok, pid} =
               SpawnProcess.spawn(
                 "workers",
                 "notify",
                 fn -> send(test_pid, :task_ran) end,
                 [%{kind: "process.spawn", params: ["workers"]}]
               )

      assert is_pid(pid)
      assert_receive :task_ran, 1000
    end

    test "blocks a pool outside the declared label without running the task" do
      test_pid = self()

      assert {:error, message} =
               SpawnProcess.spawn(
                 "reports",
                 "notify",
                 fn -> send(test_pid, :should_not_run) end,
                 [%{kind: "process.spawn", params: ["workers"]}]
               )

      assert message =~ "reports"
      refute_receive :should_not_run, 200
    end

    test "a crashing task body does not crash the caller or supervisor" do
      {:ok, _pid} =
        SpawnProcess.spawn(
          "workers",
          "crasher",
          fn -> raise "intentional crash" end,
          [%{kind: "process.spawn", params: ["workers"]}]
        )

      Process.sleep(100)
      assert Process.whereis(SpawnProcess) != nil
    end

    test "records task name and pool on the trace span" do
      Skein.Runtime.Trace.init()

      {:ok, _pid} =
        SpawnProcess.spawn("workers", "bodied-task", fn -> :ok end, [
          %{kind: "process.spawn", params: ["workers"]}
        ])

      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1[:kind] == :process and &1[:task] == "bodied-task"))

      assert span
      assert span[:pool] == "workers"
    end
  end

  describe "spawn/2" do
    test "spawns a function and returns {:ok, pid}" do
      test_pid = self()

      assert {:ok, pid} =
               SpawnProcess.spawn(
                 fn ->
                   send(test_pid, :spawned)
                 end,
                 [%{kind: "process.spawn", params: []}]
               )

      assert is_pid(pid)
      assert_receive :spawned, 1000
    end

    test "spawned process runs to completion" do
      test_pid = self()

      {:ok, _pid} =
        SpawnProcess.spawn(
          fn ->
            send(test_pid, {:result, 42})
          end,
          [%{kind: "process.spawn", params: []}]
        )

      assert_receive {:result, 42}, 1000
    end

    test "multiple processes can be spawned" do
      test_pid = self()

      {:ok, pid1} =
        SpawnProcess.spawn(fn -> send(test_pid, {:from, 1}) end, [
          %{kind: "process.spawn", params: []}
        ])

      {:ok, pid2} =
        SpawnProcess.spawn(fn -> send(test_pid, {:from, 2}) end, [
          %{kind: "process.spawn", params: []}
        ])

      {:ok, pid3} =
        SpawnProcess.spawn(fn -> send(test_pid, {:from, 3}) end, [
          %{kind: "process.spawn", params: []}
        ])

      assert pid1 != pid2
      assert pid2 != pid3

      assert_receive {:from, 1}, 1000
      assert_receive {:from, 2}, 1000
      assert_receive {:from, 3}, 1000
    end

    test "spawned process crash does not crash the supervisor" do
      {:ok, _pid} =
        SpawnProcess.spawn(
          fn ->
            raise "intentional crash"
          end,
          [%{kind: "process.spawn", params: []}]
        )

      # Give it time to crash
      Process.sleep(100)

      # Supervisor should still be running
      assert Process.whereis(SpawnProcess) != nil
    end
  end

  describe "list_children/0" do
    test "returns empty list when no children" do
      assert SpawnProcess.list_children() == []
    end

    test "returns pids of running children" do
      test_pid = self()

      {:ok, _pid} =
        SpawnProcess.spawn(
          fn ->
            send(test_pid, :ready)
            Process.sleep(5000)
          end,
          [%{kind: "process.spawn", params: []}]
        )

      assert_receive :ready, 1000
      children = SpawnProcess.list_children()
      assert length(children) >= 1
    end
  end

  describe "reset_all/0" do
    test "terminates all children" do
      test_pid = self()

      {:ok, _pid} =
        SpawnProcess.spawn(
          fn ->
            send(test_pid, :ready)
            Process.sleep(5000)
          end,
          [%{kind: "process.spawn", params: []}]
        )

      assert_receive :ready, 1000
      SpawnProcess.reset_all()
      Process.sleep(100)

      # After reset, should have no children if we restart
      # (reset_all terminates children but doesn't stop supervisor)
    end
  end

  describe "scenario capability-context propagation to spawned work (#282)" do
    test "spawn/4 work body inherits the active capability envelope" do
      parent = self()
      caps = [%{kind: "process.spawn", params: []}]
      envelope = %{tool: "T", providers: %{"uuid" => fn -> "FROM-ENVELOPE" end}}

      CapabilityStack.with_envelope(envelope, fn ->
        work = fn -> send(parent, {:resolved, resolve_uuid()}) end
        assert {:ok, _pid} = SpawnProcess.spawn(nil, "task", work, caps)
      end)

      assert_receive {:resolved, "FROM-ENVELOPE"}, 1000
    end

    test "spawn/4 work body inherits the blocked-live test policy" do
      parent = self()
      caps = [%{kind: "process.spawn", params: []}]

      TestPolicy.with_policy([], fn ->
        work = fn ->
          send(parent, {:blocked, TestPolicy.block_live?("http.out", "api.stripe.com")})
        end

        assert {:ok, _pid} = SpawnProcess.spawn(nil, "task", work, caps)
      end)

      assert_receive {:blocked, true}, 1000
    end

    test "spawn/2 work body inherits the test policy" do
      parent = self()

      TestPolicy.with_policy([], fn ->
        work = fn -> send(parent, {:active, TestPolicy.active?()}) end
        assert {:ok, _pid} = SpawnProcess.spawn(work, [%{kind: "process.spawn", params: []}])
      end)

      assert_receive {:active, true}, 1000
    end
  end

  # Resolves the "uuid" effect through the active capability stack, returning the
  # provider's value or :no_provider — used to observe envelope propagation.
  defp resolve_uuid do
    case CapabilityStack.resolve("uuid") do
      {:implement, provider} -> provider.()
      :no_provider -> :no_provider
    end
  end
end
