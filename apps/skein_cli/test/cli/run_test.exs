defmodule Skein.CLI.RunTest do
  use ExUnit.Case, async: false

  alias Skein.CLI

  @tmp_dir Path.expand("../../tmp/run_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    src_dir = Path.join(@tmp_dir, "src")
    File.mkdir_p!(src_dir)

    on_exit(fn ->
      # run/1 enables event persistence by default — clear the global flag
      # and the Repo so other tests are unaffected.
      Skein.Runtime.EventStore.Persistence.disable()

      try do
        GenServer.stop(Skein.Runtime.Repo, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir, src_dir: src_dir}
  end

  defp write_service(src_dir, module_name) do
    File.write!(Path.join(src_dir, "#{String.downcase(module_name)}.skein"), """
    module #{module_name} {
      capability http.in

      handler http GET "/health" (req) -> {
        respond.json(200, "ok")
      }
    }
    """)
  end

  describe "run/1" do
    test "compiles and starts a service with handlers", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "api.skein"), """
      module Api {
        capability http.in

        handler http GET "/health" (req) -> {
          respond.json(200, "ok")
        }
      }
      """)

      # Start the server on a random available port
      port = get_free_port()
      assert {:ok, pid} = CLI.run([tmp, "--port", "#{port}"])
      assert Process.alive?(pid)

      # Give the server a moment to start
      Process.sleep(50)

      # Verify we can connect
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          assert true

        {:error, _} ->
          flunk("Could not connect to server on port #{port}")
      end

      # Clean up
      GenServer.stop(pid)
    end

    test "defaults to the current directory with no arguments" do
      # The CLI app has no src/ directory, so the default-dir search fails
      assert {:error, message} = CLI.run([])
      assert message =~ "No .skein files found"
      assert message =~ Path.expand(".")
    end

    test "rejects unknown flags", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.run_config([tmp, "--prot", "4000"])
      assert message =~ "Unknown option: --prot"
    end

    test "returns error when no .skein files found", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.run([tmp])
      assert message =~ "No .skein files"
    end

    test "returns error when no handlers found", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "lib.skein"), """
      module Lib {
        fn helper(x: Int) -> Int { x }
      }
      """)

      assert {:error, message} = CLI.run([tmp])
      assert message =~ "No handlers"
    end

    test "uses default port 4000 when not specified", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "api.skein"), """
      module Api2 {
        capability http.in

        handler http GET "/ping" (req) -> {
          respond.json(200, "pong")
        }
      }
      """)

      # We can't actually bind 4000 in tests reliably, so just verify the
      # option parsing returns the right config
      assert {:ok, config} = CLI.run_config([tmp])
      assert config.port == 4000
    end

    test "parses --port flag", %{tmp_dir: tmp, src_dir: src} do
      File.write!(Path.join(src, "svc.skein"), """
      module Svc {
        capability http.in

        handler http GET "/ok" (req) -> {
          respond.json(200, "ok")
        }
      }
      """)

      assert {:ok, config} = CLI.run_config([tmp, "--port", "8080"])
      assert config.port == 8080
    end

    test "malformed --port returns a structured error instead of raising", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.run_config([tmp, "--port", "abc"])
      assert message =~ "--port"
      assert message =~ "abc"
    end

    test "out-of-range --port returns a structured error", %{tmp_dir: tmp} do
      assert {:error, message} = CLI.run_config([tmp, "--port", "99999"])
      assert message =~ "--port"
    end
  end

  describe "supervisor wiring (#325)" do
    defp write_pool(src_dir, module_name) do
      File.write!(Path.join(src_dir, "#{String.downcase(module_name)}.skein"), """
      module #{module_name} {
        supervisor Main {
          child Worker
        }

        agent Worker {
          enum Phase {
            Waiting -> []
          }

          on start() -> {
            transition(Phase.Waiting)
          }

          on phase(Phase.Waiting) -> {
            42
          }
        }
      }
      """)
    end

    test "a module with only a supervisor is mounted", %{tmp_dir: tmp, src_dir: src} do
      write_pool(src, "SoloPool")

      assert {:ok, config} = CLI.run_config([tmp])
      assert [mod] = config.modules
      assert mod.__supervisors__() != []
    end

    test "run boots declared supervisors with agent children", %{tmp_dir: tmp, src_dir: src} do
      write_pool(src, "RunPool")
      Skein.Runtime.EventStore.clear()

      port = get_free_port()
      assert {:ok, pid} = CLI.run([tmp, "--no-persist", "--port", "#{port}"])

      events = Skein.Runtime.EventStore.query(kind: :supervisor, event: :child_started)
      assert [event] = events
      assert event.supervisor == "Main"
      assert event.child == "Worker"

      GenServer.stop(pid)
    end
  end

  describe "event persistence (#299)" do
    test "run enables persistence at <project>/.skein/events.db by default",
         %{tmp_dir: tmp, src_dir: src} do
      write_service(src, "PersistApi")

      port = get_free_port()
      assert {:ok, pid} = CLI.run([tmp, "--port", "#{port}"])

      assert Skein.Runtime.EventStore.Persistence.enabled?()
      assert File.exists?(Path.join([tmp, ".skein", "events.db"]))

      GenServer.stop(pid)
    end

    test "--no-persist skips persistence", %{tmp_dir: tmp, src_dir: src} do
      write_service(src, "NoPersistApi")

      port = get_free_port()
      assert {:ok, pid} = CLI.run([tmp, "--no-persist", "--port", "#{port}"])

      refute Skein.Runtime.EventStore.Persistence.enabled?()
      refute File.exists?(Path.join([tmp, ".skein", "events.db"]))

      GenServer.stop(pid)
    end

    test "run_config exposes persist (default true) and project_dir",
         %{tmp_dir: tmp, src_dir: src} do
      write_service(src, "ConfigApi")

      assert {:ok, config} = CLI.run_config([tmp])
      assert config.persist == true
      assert config.project_dir == Path.expand(tmp)

      assert {:ok, config} = CLI.run_config([tmp, "--no-persist"])
      assert config.persist == false
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
