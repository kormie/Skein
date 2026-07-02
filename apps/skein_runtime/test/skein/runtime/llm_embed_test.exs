defmodule Skein.Runtime.LlmEmbedTest do
  @moduledoc """
  Unit tests for llm.embed runtime support.

  Tests the embed/3 function including:
  - Successful embedding returns a list of floats
  - Capability checking enforced
  - Trace spans recorded
  - Backend error handling
  - Failing backend returns errors
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "model", params: ["anthropic", "text-embedding-3-small"]}]
  @no_capabilities []

  setup do
    Trace.clear()
    Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    :ok
  end

  # ------------------------------------------------------------------
  # embed/3
  # ------------------------------------------------------------------

  describe "embed/3" do
    test "returns {:ok, vector} on success" do
      assert {:ok, vector} =
               Llm.embed("text-embedding-3-small", "Hello world", @valid_capabilities)

      assert is_list(vector)
      assert length(vector) > 0
      assert Enum.all?(vector, &is_float/1)
    end

    test "rejects without model capability" do
      assert {:error, {:denied, _reason}} =
               Llm.embed("text-embedding-3-small", "Hello", @no_capabilities)
    end

    test "records a trace span with model metadata" do
      Llm.embed("text-embedding-3-small", "Hello", @valid_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :llm
      assert span.method == :embed
      assert span.model == "text-embedding-3-small"
      assert span.outcome == :ok
    end

    test "handles backend errors gracefully" do
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      assert {:error, {:provider_error, "500", "Embedding failed"}} =
               Llm.embed("text-embedding-3-small", "Hello", @valid_capabilities)
    end

    test "records error outcome in trace span on failure" do
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      Llm.embed("text-embedding-3-small", "Hello", @valid_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :llm
      assert span.method == :embed
      assert span.outcome == :error
    end

    test "returns deterministic vector for same input from test backend" do
      assert {:ok, vec1} =
               Llm.embed("text-embedding-3-small", "Hello world", @valid_capabilities)

      assert {:ok, vec2} =
               Llm.embed("text-embedding-3-small", "Hello world", @valid_capabilities)

      assert vec1 == vec2
    end

    test "returns different vectors for different inputs from test backend" do
      assert {:ok, vec1} =
               Llm.embed("text-embedding-3-small", "cats", @valid_capabilities)

      assert {:ok, vec2} =
               Llm.embed("text-embedding-3-small", "quantum mechanics", @valid_capabilities)

      assert vec1 != vec2
    end
  end
end
