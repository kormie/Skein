defmodule Skein.Runtime.TraceTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Trace

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Span recording
  # ------------------------------------------------------------------

  describe "record_span/1" do
    test "records a span with required fields" do
      span = %{
        kind: :http,
        method: :get,
        url: "https://api.example.com/data",
        status: 200,
        duration_us: 1500,
        outcome: :ok
      }

      Trace.record_span(span)
      spans = Trace.recent_spans(10)
      assert length(spans) == 1
      recorded = hd(spans)
      assert recorded.kind == :http
      assert recorded.method == :get
      assert recorded.status == 200
    end

    test "records multiple spans" do
      for i <- 1..5 do
        Trace.record_span(%{
          kind: :http,
          method: :get,
          url: "https://api.example.com/#{i}",
          status: 200,
          duration_us: 100 * i,
          outcome: :ok
        })
      end

      spans = Trace.recent_spans(10)
      assert length(spans) == 5
    end

    test "adds timestamp automatically" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "https://api.example.com/data",
        status: 200,
        duration_us: 1000,
        outcome: :ok
      })

      [span] = Trace.recent_spans(1)
      assert is_integer(span.timestamp)
    end
  end

  # ------------------------------------------------------------------
  # Querying spans
  # ------------------------------------------------------------------

  describe "recent_spans/1" do
    test "returns empty list when no spans recorded" do
      assert Trace.recent_spans(10) == []
    end

    test "limits returned spans" do
      for i <- 1..10 do
        Trace.record_span(%{
          kind: :http,
          method: :get,
          url: "https://api.example.com/#{i}",
          status: 200,
          duration_us: 100,
          outcome: :ok
        })
      end

      assert length(Trace.recent_spans(3)) == 3
    end

    test "returns most recent spans first" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "first",
        status: 200,
        duration_us: 100,
        outcome: :ok
      })

      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "second",
        status: 200,
        duration_us: 100,
        outcome: :ok
      })

      [most_recent | _] = Trace.recent_spans(10)
      assert most_recent.url == "second"
    end
  end

  # ------------------------------------------------------------------
  # Clear
  # ------------------------------------------------------------------

  describe "clear/0" do
    test "removes all recorded spans" do
      Trace.record_span(%{
        kind: :http,
        method: :get,
        url: "test",
        status: 200,
        duration_us: 100,
        outcome: :ok
      })

      assert length(Trace.recent_spans(10)) == 1

      Trace.clear()
      assert Trace.recent_spans(10) == []
    end
  end

  # ------------------------------------------------------------------
  # Timed execution
  # ------------------------------------------------------------------

  describe "with_span/2" do
    test "executes function and records span with timing" do
      result =
        Trace.with_span(%{kind: :http, method: :get, url: "test"}, fn ->
          Process.sleep(5)
          {:ok, "response"}
        end)

      assert result == {:ok, "response"}

      [span] = Trace.recent_spans(1)
      assert span.kind == :http
      assert span.duration_us >= 5000
      assert span.outcome == :ok
    end

    test "records error outcome on exception" do
      assert_raise RuntimeError, fn ->
        Trace.with_span(%{kind: :http, method: :get, url: "fail"}, fn ->
          raise "boom"
        end)
      end

      [span] = Trace.recent_spans(1)
      assert span.outcome == :error
      assert span.error =~ "boom"
    end

    test "records error outcome on error tuple" do
      result =
        Trace.with_span(%{kind: :http, method: :get, url: "err"}, fn ->
          {:error, "not found"}
        end)

      assert result == {:error, "not found"}

      [span] = Trace.recent_spans(1)
      assert span.outcome == :error
    end
  end
end
