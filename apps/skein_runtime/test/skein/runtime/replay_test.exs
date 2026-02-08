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
end
