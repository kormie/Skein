defmodule Skein.Runtime.LlmStreamPropertyTest do
  @moduledoc """
  Property-based tests for LLM streaming (Phase 8f).

  Verifies that for any list of chunks:
  1. All chunks are delivered to the callback in order
  2. The assembled response equals the concatenation of all chunks
  3. Capability checking always applies regardless of chunks
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "model", params: ["anthropic", "claude-sonnet-4-5"]}]

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp chunk_list_gen do
    StreamData.list_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 50),
      min_length: 0,
      max_length: 10
    )
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "assembled response equals concatenation of all chunks" do
    check all(chunks <- chunk_list_gen()) do
      # Set up a dynamic backend that streams the generated chunks
      Llm.set_backend({Skein.Runtime.Llm.DynamicStreamBackend, chunks})

      on_chunk = fn _chunk -> :ok end

      {:ok, full_response} =
        Llm.stream(
          "claude-sonnet-4-5",
          "system",
          "input",
          on_chunk,
          @valid_capabilities
        )

      expected = Enum.join(chunks, "")
      assert full_response == expected
    end
  end

  property "all chunks are delivered to the callback in order" do
    check all(chunks <- chunk_list_gen()) do
      Llm.set_backend({Skein.Runtime.Llm.DynamicStreamBackend, chunks})

      received = :ets.new(:prop_received, [:ordered_set, :public])
      counter = :counters.new(1, [:atomics])

      on_chunk = fn chunk ->
        idx = :counters.get(counter, 1)
        :ets.insert(received, {idx, chunk})
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

      received_chunks =
        :ets.tab2list(received)
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_, chunk} -> chunk end)

      assert received_chunks == chunks
      :ets.delete(received)
    end
  end

  property "streaming always fails without capabilities" do
    check all(chunks <- chunk_list_gen()) do
      Llm.set_backend({Skein.Runtime.Llm.DynamicStreamBackend, chunks})

      on_chunk = fn _chunk -> :ok end

      assert {:error, {:denied, _reason}} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "system",
                 "input",
                 on_chunk,
                 []
               )
    end
  end

  property "every stream call produces a trace span" do
    check all(chunks <- chunk_list_gen()) do
      Trace.clear()
      Llm.set_backend({Skein.Runtime.Llm.DynamicStreamBackend, chunks})

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
      assert hd(llm_spans).method == :stream
    end
  end
end
