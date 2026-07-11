defmodule Skein.Runtime.ReplayInjectionTest do
  @moduledoc """
  Tests for replay interception of LLM, HTTP, and tool effects (issue #73).

  When `Replay.with_replay/2` is active in the calling process, effect calls
  are served from the recorded trace instead of reaching real backends. A
  failing LLM backend and dead network endpoints prove that replayed calls
  never leave the process.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Http
  alias Skein.Runtime.Llm
  alias Skein.Runtime.Replay
  alias Skein.Runtime.Tool
  alias Skein.Runtime.Trace

  @model_caps [%{kind: "model", params: ["anthropic", "test-model"]}]
  @http_caps [%{kind: "http.out", params: []}]
  @tool_caps [%{kind: "tool.use", params: []}]

  setup do
    Trace.clear()
    previous = Llm.get_backend()
    # A failing backend proves replayed calls never reach the backend.
    Llm.set_backend(Skein.Runtime.Llm.FailingBackend)
    on_exit(fn -> Llm.set_backend(previous) end)
    :ok
  end

  # ------------------------------------------------------------------
  # LLM
  # ------------------------------------------------------------------

  describe "LLM replay interception" do
    test "chat returns the recorded response without calling the backend" do
      trace = [
        %{"kind" => "llm", "method" => "chat", "model" => "test-model", "response" => "recorded!"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, "recorded!"} = Llm.chat("test-model", "sys", "hi", @model_caps)
      end)
    end

    test "chat outside replay still uses the configured backend" do
      assert {:error, {:provider_error, "500", "Internal server error"}} =
               Llm.chat("test-model", "sys", "hi", @model_caps)
    end

    test "model mismatch produces a clear error" do
      trace = [
        %{"kind" => "llm", "method" => "chat", "model" => "other-model", "response" => "x"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:provider_error, "replay", message}} =
                 Llm.chat("test-model", "sys", "hi", @model_caps)

        assert message =~ "Replay mismatch"
        assert message =~ "other-model"
      end)
    end

    test "method mismatch produces a clear error" do
      trace = [
        %{"kind" => "llm", "method" => "chat", "model" => "test-model", "response" => "x"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:provider_error, "replay", message}} =
                 Llm.json("test-model", "sys", "hi", %{}, @model_caps)

        assert message =~ "Replay mismatch"
      end)
    end

    test "exhausted trace produces a clear error" do
      trace = [
        %{"kind" => "llm", "method" => "chat", "model" => "test-model", "response" => "only"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, "only"} = Llm.chat("test-model", "sys", "hi", @model_caps)

        assert {:error, {:provider_error, "replay", message}} =
                 Llm.chat("test-model", "sys", "hi again", @model_caps)

        assert message =~ "exhausted"
      end)
    end

    test "json parses a recorded raw JSON response" do
      trace = [
        %{
          "kind" => "llm",
          "method" => "json",
          "model" => "test-model",
          "response" => ~s({"action":"approve"})
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"action" => "approve"}} =
                 Llm.json("test-model", "sys", "hi", %{}, @model_caps)
      end)
    end

    test "json accepts a recorded already-parsed map response" do
      trace = [
        %{
          "kind" => "llm",
          "method" => "json",
          "model" => "test-model",
          "response" => %{"action" => "deny"}
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"action" => "deny"}} =
                 Llm.json("test-model", "sys", "hi", %{}, @model_caps)
      end)
    end

    test "stream delivers a recorded assembled response as a chunk" do
      trace = [
        %{
          "kind" => "llm",
          "method" => "stream",
          "model" => "test-model",
          "response" => "streamed text"
        }
      ]

      parent = self()

      Replay.with_replay(trace, fn ->
        assert {:ok, "streamed text"} =
                 Llm.stream("test-model", "sys", "hi", &send(parent, {:chunk, &1}), @model_caps)
      end)

      assert_received {:chunk, "streamed text"}
    end

    test "embed returns a recorded vector" do
      trace = [
        %{"kind" => "llm", "method" => "embed", "model" => "test-model", "response" => [0.1, 0.2]}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, [0.1, 0.2]} = Llm.embed("test-model", "hi", @model_caps)
      end)
    end

    test "capability checks still apply during replay and do not consume events" do
      trace = [
        %{"kind" => "llm", "method" => "chat", "model" => "test-model", "response" => "x"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:denied, _reason}} =
                 Llm.chat("test-model", "sys", "hi", [])

        assert {:ok, "x"} = Llm.chat("test-model", "sys", "hi", @model_caps)
      end)
    end
  end

  describe "LLM span recording" do
    test "chat records the full response on its span" do
      Llm.set_backend(Skein.Runtime.Llm.TestBackend)
      assert {:ok, response} = Llm.chat("test-model", "sys", "hello", @model_caps)

      assert [span] = Trace.recent_spans(1)
      assert span.response == response
    end

    test "embed records the vector on its span" do
      Llm.set_backend(Skein.Runtime.Llm.TestBackend)
      assert {:ok, vector} = Llm.embed("test-model", "hello", @model_caps)

      assert [span] = Trace.recent_spans(1)
      assert span.response == vector
    end
  end

  # ------------------------------------------------------------------
  # HTTP
  # ------------------------------------------------------------------

  describe "HTTP replay interception" do
    test "get returns the recorded body without any network call" do
      trace = [
        %{
          "kind" => "http",
          "method" => "get",
          "url" => "http://localhost:1/data",
          "status" => 200,
          "response_body" => ~s({"ok":true})
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{status: 200, body: %{"ok" => true}}} =
                 Http.get("http://localhost:1/data", @http_caps)
      end)
    end

    test "a recorded non-2xx status replays as Err(Status(code, body))" do
      trace = [
        %{
          "kind" => "http",
          "method" => "get",
          "url" => "http://localhost:1/missing",
          "status" => 404,
          "response_body" => "not found"
        }
      ]

      # A non-2xx is the spec HttpError.Status variant the caller can match on
      # (skein-testing#22), no longer an opaque raise.
      Replay.with_replay(trace, fn ->
        assert {:error, {:status, 404, "not found"}} =
                 Http.get("http://localhost:1/missing", @http_caps)
      end)
    end

    test "method mismatch produces a clear error" do
      trace = [
        %{
          "kind" => "http",
          "method" => "post",
          "url" => "http://localhost:1/a",
          "status" => 200,
          "response_body" => ""
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:denied, message}} = Http.get("http://localhost:1/a", @http_caps)
        assert message =~ "Replay mismatch"
      end)
    end

    test "url mismatch produces a clear error" do
      trace = [
        %{
          "kind" => "http",
          "method" => "get",
          "url" => "http://localhost:1/a",
          "status" => 200,
          "response_body" => ""
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:denied, message}} = Http.get("http://localhost:1/b", @http_caps)
        assert message =~ "Replay mismatch"
        assert message =~ "http://localhost:1/a"
      end)
    end

    test "exhausted trace produces a clear error" do
      Replay.with_replay([], fn ->
        assert {:error, {:denied, message}} = Http.get("http://localhost:1/a", @http_caps)
        assert message =~ "exhausted"
      end)
    end

    test "capability checks still apply during replay" do
      trace = [
        %{
          "kind" => "http",
          "method" => "get",
          "url" => "https://api.blocked.com/x",
          "status" => 200,
          "response_body" => "y"
        }
      ]

      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]

      Replay.with_replay(trace, fn ->
        assert {:error, {:denied, reason}} = Http.get("https://api.blocked.com/x", capabilities)
        assert reason =~ "not declared"
      end)
    end

    test "live requests record status and response body for later replay" do
      port = serve_once(200, ~s({"live": true}))
      url = "http://localhost:#{port}/data"

      assert {:ok, %{status: 200, body: %{"live" => true}}} = Http.get(url, @http_caps)

      trace = exported_trace()

      Replay.with_replay(trace, fn ->
        # The one-shot server is gone — only the recording can answer.
        assert {:ok, %{status: 200, body: %{"live" => true}}} = Http.get(url, @http_caps)
      end)
    end
  end

  # ------------------------------------------------------------------
  # Tools
  # ------------------------------------------------------------------

  describe "tool replay interception" do
    setup do
      Tool.clear_registry()
      parent = self()

      Tool.register("echo", %{}, fn input ->
        send(parent, {:tool_executed, input})
        {:ok, %{"echoed" => input}}
      end)

      on_exit(fn -> Tool.clear_registry() end)
      :ok
    end

    test "call returns the recorded response without executing the implementation" do
      trace = [
        %{
          "kind" => "tool",
          "method" => "call",
          "name" => "echo",
          "response" => %{"echoed" => "recorded"}
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"echoed" => "recorded"}} = Tool.call("echo", %{}, @tool_caps)
      end)

      refute_received {:tool_executed, _}
    end

    test "tool name mismatch produces a clear error" do
      trace = [
        %{"kind" => "tool", "method" => "call", "name" => "other_tool", "response" => %{}}
      ]

      Replay.with_replay(trace, fn ->
        assert {:error, {:execution_error, "echo", error_message}} =
                 Tool.call("echo", %{}, @tool_caps)

        assert error_message =~ "Replay mismatch"
        assert error_message =~ "other_tool"
      end)

      refute_received {:tool_executed, _}
    end

    test "exhausted trace produces a clear error" do
      Replay.with_replay([], fn ->
        assert {:error, {:execution_error, "echo", error_message}} =
                 Tool.call("echo", %{}, @tool_caps)

        assert error_message =~ "exhausted"
      end)

      refute_received {:tool_executed, _}
    end

    test "recorded list and schema spans do not occupy the call sequence" do
      trace = [
        %{"kind" => "tool", "method" => "list", "name" => "*"},
        %{
          "kind" => "tool",
          "method" => "call",
          "name" => "echo",
          "response" => %{"echoed" => "after list"}
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"echoed" => "after list"}} = Tool.call("echo", %{}, @tool_caps)
      end)
    end

    test "live calls record the result for later replay" do
      assert {:ok, %{"echoed" => %{"q" => 1}}} = Tool.call("echo", %{"q" => 1}, @tool_caps)
      assert_received {:tool_executed, _}

      trace = exported_trace()
      Tool.clear_registry()

      Replay.with_replay(trace, fn ->
        # Registry is empty — only the recording can answer.
        assert {:ok, %{"echoed" => %{"q" => 1}}} = Tool.call("echo", %{"q" => 1}, @tool_caps)
      end)

      refute_received {:tool_executed, _}
    end
  end

  # ------------------------------------------------------------------
  # Record-then-replay round trip
  # ------------------------------------------------------------------

  describe "record-then-replay round trip" do
    test "an LLM run replays identically with zero backend calls" do
      Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      run = fn ->
        {:ok, text} = Llm.chat("test-model", "sys", "What is up?", @model_caps)
        {:ok, decision} = Llm.json("test-model", "sys", "Decide.", %{}, @model_caps)
        {text, decision}
      end

      live_result = run.()
      trace = exported_trace()

      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      replayed_result = Replay.with_replay(trace, run)

      assert replayed_result == live_result
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Round-trips recorded spans through JSON, oldest first, the way a
  # trace file written to disk would look.
  defp exported_trace do
    Trace.recent_spans(100)
    |> Enum.reverse()
    |> Enum.map(&Map.delete(&1, :_key))
    |> Jason.encode!()
    |> Jason.decode!()
  end

  # One-shot HTTP server: answers a single request with the given status
  # and body, then closes. The port is dead afterwards.
  defp serve_once(status, body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      response =
        "HTTP/1.1 #{status} OK\r\ncontent-length: #{byte_size(body)}\r\n" <>
          "connection: close\r\n\r\n#{body}"

      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end
  # ------------------------------------------------------------------
  # Process/timer replay
  # ------------------------------------------------------------------

  describe "process and timer replay interception" do
    test "process.spawn replays without starting background work" do
      parent = self()
      trace = [
        %{"kind" => "process", "method" => "spawn", "task" => "notify", "pool" => "workers", "result" => "ok"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, pid} =
                 Skein.Runtime.Process.spawn("workers", "notify", fn -> send(parent, :ran) end, [
                   %{kind: "process.spawn", params: ["workers"]}
                 ])

        assert is_pid(pid)
      end)

      refute_received :ran
    end

    test "timer.after replays the recorded ref without scheduling a callback" do
      parent = self()
      trace = [
        %{"kind" => "timer", "method" => "after", "delay_ms" => 1, "group" => "maintenance", "timer_ref" => "timer-123"}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, "timer-123"} =
                 apply(Skein.Runtime.Timer, :after, [
                   "maintenance",
                   1,
                   fn -> send(parent, :fired) end,
                   [%{kind: "timer", params: ["maintenance"]}]
                 ])
      end)

      refute_received :fired
    end
  end

end
