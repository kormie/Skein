defmodule Skein.CLI.RenderTest do
  @moduledoc """
  Golden tests for the pure CLI renderer (#284). Output is byte-stable and
  total over every span kind, so `skein trace` never crashes on a real span.
  """
  use ExUnit.Case, async: true

  alias Skein.CLI
  alias Skein.CLI.Render
  alias Skein.Runtime.Trace

  describe "trace/1 (pure, byte-stable)" do
    test "renders http + llm spans to the exact golden string" do
      result = %{
        count: 2,
        spans: [
          %{
            kind: :http,
            method: :get,
            url: "/test",
            status: 200,
            outcome: :ok,
            duration_us: 1500
          },
          %{kind: :llm, method: :chat, url: "openai", outcome: :ok, duration_us: 3200}
        ]
      }

      assert Render.trace(result) == """
             Traces (2):
               [http] get /test -> 200 ok (1.5ms)
               [llm] chat openai ok (3.2ms)
             """
    end

    test "an empty trace renders just the header" do
      assert Render.trace(%{count: 0, spans: []}) == "Traces (0):\n"
    end

    test "a span missing method/url/status renders without crashing" do
      result = %{count: 1, spans: [%{kind: :uuid, duration_us: 100}]}
      assert Render.trace(result) == "Traces (1):\n  [uuid] (0.1ms)\n"
    end

    test "string-keyed spans (replayed from JSON) render identically" do
      result = %{
        count: 1,
        spans: [%{"kind" => "http", "method" => "post", "url" => "/x", "duration_us" => 2000}]
      }

      assert Render.trace(result) == "Traces (1):\n  [http] post /x (2.0ms)\n"
    end

    test "a span with no recognized fields still renders a line" do
      assert Render.trace(%{count: 1, spans: [%{}]}) == "Traces (1):\n  [?]\n"
    end
  end

  describe "TTY/TUI seam: plain output is identical across modes" do
    setup do
      Trace.init()
      Trace.clear()

      Trace.record_span(%{kind: :http, method: :get, url: "/a", outcome: :ok, duration_us: 1000})
      :ok
    end

    test "trace, --no-tui, and --interactive produce byte-identical rendered output" do
      assert {:ok, plain} = CLI.trace([])
      assert {:ok, no_tui} = CLI.trace(["--no-tui"])
      assert {:ok, interactive} = CLI.trace(["--interactive"])

      rendered = Render.trace(plain)
      assert rendered == Render.trace(no_tui)
      assert rendered == Render.trace(interactive)
      assert rendered =~ "[http] get /a ok (1.0ms)"
    end
  end
end
