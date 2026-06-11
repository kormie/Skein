defmodule Skein.Runtime.ReplayTest do
  @moduledoc """
  Tests for the Skein replay engine used by golden trace tests.
  """
  use ExUnit.Case, async: true

  alias Skein.Runtime.Replay

  @tmp_dir Path.expand("../../tmp/replay_test", __DIR__)

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    %{tmp_dir: @tmp_dir}
  end

  # ------------------------------------------------------------------
  # load_trace/1
  # ------------------------------------------------------------------

  describe "load_trace/1" do
    test "loads a valid JSON trace file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "valid.json")

      File.write!(
        path,
        Jason.encode!([
          %{kind: "handler", method: "get", path: "/hello", status: 200}
        ])
      )

      spans = Replay.load_trace(path)
      assert is_list(spans)
      assert length(spans) == 1
      assert %{"kind" => "handler", "method" => "get"} = hd(spans)
    end

    test "loads an empty trace file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "empty.json")
      File.write!(path, "[]")

      assert [] = Replay.load_trace(path)
    end

    test "loads a multi-span trace file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "multi.json")

      File.write!(
        path,
        Jason.encode!([
          %{kind: "handler", method: "get", path: "/a"},
          %{kind: "llm", model: "gpt-4"},
          %{kind: "memory", operation: "put", key: "foo"}
        ])
      )

      spans = Replay.load_trace(path)
      assert length(spans) == 3
    end

    test "raises on missing file" do
      assert_raise RuntimeError, ~r/Could not read golden trace file/, fn ->
        Replay.load_trace("/nonexistent/path.json")
      end
    end

    test "raises on invalid JSON", %{tmp_dir: tmp} do
      path = Path.join(tmp, "bad.json")
      File.write!(path, "{not valid json")

      assert_raise RuntimeError, ~r/invalid JSON/, fn ->
        Replay.load_trace(path)
      end
    end

    test "raises when JSON is not an array", %{tmp_dir: tmp} do
      path = Path.join(tmp, "object.json")
      File.write!(path, ~s({"kind": "handler"}))

      assert_raise RuntimeError, ~r/must contain a JSON array/, fn ->
        Replay.load_trace(path)
      end
    end
  end

  # ------------------------------------------------------------------
  # replay/1
  # ------------------------------------------------------------------

  describe "replay/1" do
    test "replays handler spans" do
      spans = [%{"kind" => "handler", "method" => "get", "path" => "/hello", "status" => 200}]
      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :handler
      assert result.method == "get"
      assert result.replayed == true
    end

    test "replays LLM spans" do
      spans = [%{"kind" => "llm", "model" => "gpt-4"}]
      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :llm
      assert result.model == "gpt-4"
      assert result.replayed == true
    end

    test "replays memory spans" do
      spans = [%{"kind" => "memory", "operation" => "put"}]
      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :memory
      assert result.operation == "put"
    end

    test "replays HTTP spans" do
      spans = [%{"kind" => "http", "method" => "post", "url" => "https://api.example.com"}]
      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :http
      assert result.method == "post"
    end

    test "replays unknown spans gracefully" do
      spans = [%{"kind" => "custom", "data" => "value"}]
      [{_span, result}] = Replay.replay(spans)
      assert result.kind == :unknown
      assert result.replayed == true
    end

    test "replays empty trace" do
      assert [] = Replay.replay([])
    end

    test "replays mixed span types" do
      spans = [
        %{"kind" => "handler", "method" => "get", "path" => "/"},
        %{"kind" => "llm", "model" => "claude"},
        %{"kind" => "memory", "operation" => "get"}
      ]

      results = Replay.replay(spans)
      assert length(results) == 3
      kinds = Enum.map(results, fn {_span, result} -> result.kind end)
      assert kinds == [:handler, :llm, :memory]
    end
  end

  # ------------------------------------------------------------------
  # Recorded response injection
  # ------------------------------------------------------------------

  describe "start_replay/2 and with_replay/2" do
    test "injects recorded LLM responses via replay backend" do
      trace = [
        %{
          "kind" => "llm",
          "model" => "gpt-4",
          "input" => "What is 2+2?",
          "response" => "4"
        },
        %{
          "kind" => "llm",
          "model" => "gpt-4",
          "input" => "What is 3+3?",
          "response" => "6"
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, "4"} = Replay.next_response(:llm)
        assert {:ok, "6"} = Replay.next_response(:llm)
        assert :exhausted = Replay.next_response(:llm)
      end)
    end

    test "injects recorded HTTP responses" do
      trace = [
        %{
          "kind" => "http",
          "method" => "GET",
          "url" => "https://api.example.com/data",
          "status" => 200,
          "response_body" => ~s({"ok": true})
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"status" => 200, "response_body" => ~s({"ok": true})}} =
                 Replay.next_response(:http)
      end)
    end

    test "replay state is process-scoped" do
      trace = [
        %{"kind" => "llm", "model" => "gpt-4", "response" => "hello"}
      ]

      Replay.with_replay(trace, fn ->
        # In another process, no replay state
        task =
          Task.async(fn ->
            Replay.next_response(:llm)
          end)

        assert :no_replay = Task.await(task)
        # In this process, it works
        assert {:ok, "hello"} = Replay.next_response(:llm)
      end)
    end

    test "replay cleans up after with_replay" do
      trace = [%{"kind" => "llm", "response" => "hi"}]

      Replay.with_replay(trace, fn ->
        assert {:ok, "hi"} = Replay.next_response(:llm)
      end)

      # After with_replay, no replay state
      assert :no_replay = Replay.next_response(:llm)
    end
  end

  # ------------------------------------------------------------------
  # active?/0
  # ------------------------------------------------------------------

  describe "active?/0" do
    test "is false outside a replay context" do
      refute Replay.active?()
    end

    test "is true inside with_replay, including for an empty trace" do
      Replay.with_replay([], fn ->
        assert Replay.active?()
      end)

      refute Replay.active?()
    end
  end

  # ------------------------------------------------------------------
  # next_response/2 (validated consumption)
  # ------------------------------------------------------------------

  describe "next_response/2" do
    test "returns the response when expected metadata matches" do
      trace = [%{"kind" => "llm", "method" => "chat", "model" => "m1", "response" => "hi"}]

      Replay.with_replay(trace, fn ->
        assert {:ok, "hi"} = Replay.next_response(:llm, %{model: "m1", method: :chat})
      end)
    end

    test "skips validation for keys the recorded event does not carry" do
      trace = [%{"kind" => "llm", "response" => "hi"}]

      Replay.with_replay(trace, fn ->
        assert {:ok, "hi"} = Replay.next_response(:llm, %{model: "m1", method: :chat})
      end)
    end

    test "returns a mismatch without consuming the event" do
      trace = [%{"kind" => "llm", "method" => "chat", "model" => "m1", "response" => "hi"}]

      Replay.with_replay(trace, fn ->
        assert {:mismatch, message} = Replay.next_response(:llm, %{model: "m2"})
        assert message =~ "Replay mismatch"
        assert message =~ "m1"
        assert message =~ "m2"

        # The mismatched event is still there for a correctly-sequenced call.
        assert {:ok, "hi"} = Replay.next_response(:llm, %{model: "m1"})
      end)
    end

    test "compares methods case-insensitively" do
      trace = [
        %{
          "kind" => "http",
          "method" => "GET",
          "url" => "https://x.test/a",
          "status" => 200,
          "response_body" => "ok"
        }
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"status" => 200, "response_body" => "ok"}} =
                 Replay.next_response(:http, %{method: :get, url: "https://x.test/a"})
      end)
    end

    test "returns :exhausted when all events of the kind are consumed" do
      Replay.with_replay([], fn ->
        assert :exhausted = Replay.next_response(:llm, %{model: "m1"})
      end)
    end

    test "returns :no_replay outside a replay context" do
      assert :no_replay = Replay.next_response(:llm, %{model: "m1"})
    end
  end

  # ------------------------------------------------------------------
  # with_replay/2 event normalization
  # ------------------------------------------------------------------

  describe "with_replay/2 event normalization" do
    test "accepts atom-keyed events straight from the in-memory event store" do
      trace = [%{kind: :llm, method: :chat, model: "m1", response: "hello"}]

      Replay.with_replay(trace, fn ->
        assert {:ok, "hello"} = Replay.next_response(:llm, %{model: "m1", method: :chat})
      end)
    end

    test "extracts tool responses from recorded tool call events" do
      trace = [
        %{"kind" => "tool", "method" => "call", "name" => "echo", "response" => %{"x" => 1}}
      ]

      Replay.with_replay(trace, fn ->
        assert {:ok, %{"x" => 1}} = Replay.next_response(:tool, %{name: "echo"})
      end)
    end
  end
end
