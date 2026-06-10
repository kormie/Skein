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
      File.rm_rf!(@tmp_dir)
    end)

    %{tmp_dir: @tmp_dir, src_dir: src_dir}
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

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
