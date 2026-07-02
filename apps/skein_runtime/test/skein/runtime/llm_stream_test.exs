defmodule Skein.Runtime.LlmStreamTest do
  @moduledoc """
  Tests for LLM streaming support (Phase 8f).

  TDD: These tests are written first, before the implementation.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "model", params: ["anthropic", "claude-sonnet-4-5"]}]
  @no_capabilities []

  setup do
    Trace.clear()
    Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)
    :ok
  end

  # ------------------------------------------------------------------
  # stream/5 — basic functionality
  # ------------------------------------------------------------------

  describe "stream/5" do
    test "streams chunks to callback and returns assembled response" do
      collector = self()

      on_chunk = fn chunk ->
        send(collector, {:chunk, chunk})
      end

      assert {:ok, full_response} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "You are helpful.",
                 "Hello",
                 on_chunk,
                 @valid_capabilities
               )

      assert is_binary(full_response)
      assert full_response == "Hello, world!"

      # Verify chunks were delivered
      assert_received {:chunk, "Hello, "}
      assert_received {:chunk, "world!"}
    end

    test "returns empty string when backend streams no chunks" do
      Llm.set_backend(Skein.Runtime.Llm.EmptyStreamBackend)

      on_chunk = fn _chunk -> :ok end

      assert {:ok, ""} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "system",
                 "input",
                 on_chunk,
                 @valid_capabilities
               )
    end

    test "rejects without model capability" do
      on_chunk = fn _chunk -> :ok end

      assert {:error, {:denied, _reason}} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "system",
                 "input",
                 on_chunk,
                 @no_capabilities
               )
    end

    test "handles backend errors during streaming" do
      Llm.set_backend(Skein.Runtime.Llm.FailingStreamBackend)

      on_chunk = fn _chunk -> :ok end

      assert {:error, {:provider_error, "500", "Stream failed"}} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "system",
                 "input",
                 on_chunk,
                 @valid_capabilities
               )
    end
  end

  # ------------------------------------------------------------------
  # Tracing
  # ------------------------------------------------------------------

  describe "stream tracing" do
    test "records a trace span with :stream method" do
      on_chunk = fn _chunk -> :ok end

      Llm.stream(
        "claude-sonnet-4-5",
        "system",
        "input",
        on_chunk,
        @valid_capabilities
      )

      spans = Trace.recent_spans(10)
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))
      assert length(llm_spans) >= 1

      span = hd(llm_spans)
      assert span.kind == :llm
      assert span.method == :stream
      assert span.model == "claude-sonnet-4-5"
      assert is_integer(span.duration_us)
      assert span.outcome == :ok
    end

    test "records error outcome on backend failure" do
      Llm.set_backend(Skein.Runtime.Llm.FailingStreamBackend)
      on_chunk = fn _chunk -> :ok end

      Llm.stream(
        "claude-sonnet-4-5",
        "system",
        "input",
        on_chunk,
        @valid_capabilities
      )

      spans = Trace.recent_spans(10)
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))
      assert length(llm_spans) >= 1

      span = hd(llm_spans)
      assert span.outcome == :error
    end
  end

  # ------------------------------------------------------------------
  # Chunk counting
  # ------------------------------------------------------------------

  describe "chunk delivery" do
    test "delivers all chunks in order" do
      chunks_received = :ets.new(:chunks_received, [:ordered_set, :public])
      counter = :counters.new(1, [:atomics])

      on_chunk = fn chunk ->
        idx = :counters.get(counter, 1)
        :ets.insert(chunks_received, {idx, chunk})
        :counters.add(counter, 1, 1)
      end

      {:ok, _} =
        Llm.stream(
          "claude-sonnet-4-5",
          "system",
          "input",
          on_chunk,
          @valid_capabilities
        )

      ordered_chunks =
        :ets.tab2list(chunks_received)
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, chunk} -> chunk end)

      assert ordered_chunks == ["Hello, ", "world!"]
      :ets.delete(chunks_received)
    end
  end
end
