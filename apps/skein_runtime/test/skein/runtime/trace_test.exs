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

  # ------------------------------------------------------------------
  # Annotations
  # ------------------------------------------------------------------

  describe "annotate/2" do
    test "records an annotation with key and value" do
      Trace.annotate("user_id", "u-123")

      spans = Trace.recent_spans(10)
      assert length(spans) == 1
      annotation = hd(spans)
      assert annotation.kind == :annotation
      assert annotation.key == "user_id"
      assert annotation.value == "u-123"
    end

    test "records multiple annotations" do
      Trace.annotate("request_id", "req-1")
      Trace.annotate("user_id", "u-456")

      spans = Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      assert length(annotations) == 2

      keys = Enum.map(annotations, & &1.key) |> Enum.sort()
      assert keys == ["request_id", "user_id"]
    end

    test "annotation has a timestamp" do
      Trace.annotate("key", "value")

      [annotation] = Trace.recent_spans(1)
      assert is_integer(annotation.timestamp)
    end

    test "annotations interleave with regular spans" do
      Trace.record_span(%{kind: :http, method: :get, url: "test"})
      Trace.annotate("step", "after_http")
      Trace.record_span(%{kind: :http, method: :post, url: "test2"})

      spans = Trace.recent_spans(10)
      assert length(spans) == 3

      kinds = Enum.map(spans, & &1.kind)
      # Most recent first
      assert kinds == [:http, :annotation, :http]
    end

    test "returns :ok" do
      assert :ok = Trace.annotate("key", "value")
    end
  end

  describe "annotate/3 (with capabilities)" do
    test "ignores capabilities and records annotation" do
      Trace.annotate("ticket_id", "T-789", [%{kind: "some.cap"}])

      [annotation] = Trace.recent_spans(1)
      assert annotation.kind == :annotation
      assert annotation.key == "ticket_id"
      assert annotation.value == "T-789"
    end

    test "returns :ok" do
      assert :ok = Trace.annotate("key", "value", [])
    end
  end

  # ------------------------------------------------------------------
  # Property tests: annotate
  # ------------------------------------------------------------------

  if Code.ensure_loaded?(StreamData) do
    describe "annotate property tests" do
      use ExUnitProperties

      property "arbitrary key/value strings produce valid annotations" do
        check all(
                key <- string(:printable, min_length: 1, max_length: 100),
                value <- string(:printable, min_length: 0, max_length: 500)
              ) do
          Trace.clear()
          assert :ok = Trace.annotate(key, value)

          [annotation] = Trace.recent_spans(1)
          assert annotation.kind == :annotation
          assert annotation.key == key
          assert annotation.value == value
          assert is_integer(annotation.timestamp)
        end
      end

      property "special characters in keys don't break storage" do
        check all(key <- string(:printable, min_length: 1, max_length: 50)) do
          Trace.clear()
          Trace.annotate(key, "test")

          [annotation] = Trace.recent_spans(1)
          assert annotation.key == key
        end
      end

      property "annotations appear in recent_spans alongside regular spans" do
        check all(
                n <- integer(1..5),
                keys <- list_of(string(:alphanumeric, min_length: 1, max_length: 20), length: n)
              ) do
          Trace.clear()

          # Record a regular span
          Trace.record_span(%{kind: :http, method: :get, url: "test"})

          # Record n annotations
          Enum.each(keys, fn key -> Trace.annotate(key, "v") end)

          spans = Trace.recent_spans(n + 1)
          assert length(spans) == n + 1

          annotations = Enum.filter(spans, &(&1.kind == :annotation))
          assert length(annotations) == n
        end
      end
    end
  end
end
