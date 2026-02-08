defmodule Skein.CLI.TraceTest do
  use ExUnit.Case, async: false

  alias Skein.CLI
  alias Skein.Runtime.Trace

  setup do
    Trace.init()
    Trace.clear()
    :ok
  end

  describe "trace/1" do
    test "returns recent traces" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "/test",
        outcome: :ok,
        duration_us: 1500
      })

      Trace.record_span(%{
        kind: :llm,
        method: :chat,
        url: "openai",
        outcome: :ok,
        duration_us: 3200
      })

      assert {:ok, result} = CLI.trace([])
      assert length(result.spans) == 2
    end

    test "respects --last flag to limit results" do
      for i <- 1..20 do
        Trace.record_span(%{
          kind: :http,
          method: :get,
          url: "/item/#{i}",
          outcome: :ok,
          duration_us: i * 100
        })
      end

      assert {:ok, result} = CLI.trace(["--last", "5"])
      assert length(result.spans) == 5
    end

    test "defaults to last 10 traces" do
      for i <- 1..15 do
        Trace.record_span(%{
          kind: :http,
          method: :get,
          url: "/item/#{i}",
          outcome: :ok,
          duration_us: i * 100
        })
      end

      assert {:ok, result} = CLI.trace([])
      assert length(result.spans) == 10
    end

    test "returns empty list when no traces exist" do
      assert {:ok, result} = CLI.trace([])
      assert result.spans == []
      assert result.count == 0
    end

    test "traces are ordered newest first" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "/first",
        outcome: :ok,
        duration_us: 100
      })

      Process.sleep(1)

      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "/second",
        outcome: :ok,
        duration_us: 200
      })

      assert {:ok, result} = CLI.trace([])
      [newest, oldest] = result.spans
      assert newest.url == "/second"
      assert oldest.url == "/first"
    end

    test "formats trace data with key fields" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "/api/users",
        outcome: :ok,
        duration_us: 2500,
        status: 200
      })

      assert {:ok, result} = CLI.trace([])
      [span] = result.spans
      assert span.kind == :http
      assert span.method == :get
      assert span.outcome == :ok
      assert span.duration_us == 2500
    end

    test "filters by kind when --kind flag provided" do
      Trace.record_span(%{kind: :http, method: :get, url: "/api", outcome: :ok, duration_us: 100})

      Trace.record_span(%{
        kind: :llm,
        method: :chat,
        url: "openai",
        outcome: :ok,
        duration_us: 200
      })

      Trace.record_span(%{
        kind: :http,
        method: :post,
        url: "/api",
        outcome: :ok,
        duration_us: 300
      })

      assert {:ok, result} = CLI.trace(["--kind", "http"])
      assert length(result.spans) == 2
      assert Enum.all?(result.spans, &(&1.kind == :http))
    end
  end
end
