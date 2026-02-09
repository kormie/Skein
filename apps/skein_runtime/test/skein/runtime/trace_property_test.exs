defmodule Skein.Runtime.TracePropertyTest do
  @moduledoc """
  Property-based tests for the Skein runtime trace module.

  Tests span recording, ordering, and `with_span` timing semantics
  across varied metadata and result types.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Trace

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp kind_gen do
    StreamData.member_of([:http, :store, :memory, :llm, :queue, :schedule])
  end

  defp method_gen do
    StreamData.member_of([:get, :post, :put, :delete, :query, :chat, :json, :list, :stream])
  end

  defp outcome_gen do
    StreamData.member_of([:ok, :error])
  end

  defp span_gen do
    gen all(
          kind <- kind_gen(),
          method <- method_gen(),
          outcome <- outcome_gen(),
          duration <- StreamData.integer(0..100_000)
        ) do
      %{
        kind: kind,
        method: method,
        outcome: outcome,
        duration_us: duration
      }
    end
  end

  defp result_gen do
    StreamData.one_of([
      StreamData.map(StreamData.string(:alphanumeric, min_length: 1, max_length: 20), fn s ->
        {:ok, s}
      end),
      StreamData.map(StreamData.string(:alphanumeric, min_length: 1, max_length: 20), fn s ->
        {:error, s}
      end),
      StreamData.integer(),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ])
  end

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "record_span preserves all metadata fields" do
    check all(span <- span_gen()) do
      Trace.clear()
      Trace.record_span(span)
      [recorded] = Trace.recent_spans(1)

      assert recorded.kind == span.kind
      assert recorded.method == span.method
      assert recorded.outcome == span.outcome
      assert recorded.duration_us == span.duration_us
      assert is_integer(recorded.timestamp)
    end
  end

  property "recent_spans returns at most count spans" do
    check all(
            spans <- StreamData.list_of(span_gen(), min_length: 1, max_length: 20),
            count <- StreamData.integer(1..25)
          ) do
      Trace.clear()

      for span <- spans do
        Trace.record_span(span)
      end

      result = Trace.recent_spans(count)
      assert length(result) == min(length(spans), count)
    end
  end

  property "recent_spans returns newest first" do
    check all(
            spans <- StreamData.list_of(span_gen(), min_length: 2, max_length: 10)
          ) do
      Trace.clear()

      for span <- spans do
        Trace.record_span(span)
      end

      result = Trace.recent_spans(length(spans))
      timestamps = Enum.map(result, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, :desc)
    end
  end

  property "clear removes all spans" do
    check all(spans <- StreamData.list_of(span_gen(), min_length: 1, max_length: 10)) do
      Trace.clear()

      for span <- spans do
        Trace.record_span(span)
      end

      Trace.clear()
      assert Trace.recent_spans(100) == []
    end
  end

  property "with_span returns the function's result unchanged" do
    check all(
            result <- result_gen(),
            kind <- kind_gen(),
            method <- method_gen()
          ) do
      Trace.clear()
      metadata = %{kind: kind, method: method}

      actual = Trace.with_span(metadata, fn -> result end)
      assert actual == result
    end
  end

  property "with_span records outcome based on return value" do
    check all(
            kind <- kind_gen(),
            method <- method_gen(),
            value <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      Trace.clear()
      metadata = %{kind: kind, method: method}

      # ok tuple -> :ok outcome
      Trace.with_span(metadata, fn -> {:ok, value} end)
      [span_ok] = Trace.recent_spans(1)
      assert span_ok.outcome == :ok

      Trace.clear()

      # error tuple -> :error outcome
      Trace.with_span(metadata, fn -> {:error, value} end)
      [span_err] = Trace.recent_spans(1)
      assert span_err.outcome == :error
    end
  end

  property "with_span records non-negative duration" do
    check all(
            kind <- kind_gen(),
            method <- method_gen()
          ) do
      Trace.clear()
      metadata = %{kind: kind, method: method}

      Trace.with_span(metadata, fn -> :ok end)
      [span] = Trace.recent_spans(1)
      assert span.duration_us >= 0
    end
  end
end
