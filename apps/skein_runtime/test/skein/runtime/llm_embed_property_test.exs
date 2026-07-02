defmodule Skein.Runtime.LlmEmbedPropertyTest do
  @moduledoc """
  Property-based tests for LLM embedding.

  Verifies that for any input string:
  1. Embedding always returns a list of floats
  2. Vector dimensionality is consistent per model
  3. Capability checking always applies
  4. Every embed call produces a trace span
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "model", params: ["anthropic", "text-embedding-3-small"]}]

  setup do
    Trace.clear()
    Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    :ok
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp input_text_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 200)
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "embed always returns a list of floats for valid input" do
    check all(input <- input_text_gen()) do
      assert {:ok, vector} =
               Llm.embed("text-embedding-3-small", input, @valid_capabilities)

      assert is_list(vector)
      assert length(vector) > 0
      assert Enum.all?(vector, &is_float/1)
    end
  end

  property "vector dimensionality is consistent for the same model" do
    check all(
            input1 <- input_text_gen(),
            input2 <- input_text_gen()
          ) do
      {:ok, vec1} = Llm.embed("text-embedding-3-small", input1, @valid_capabilities)
      {:ok, vec2} = Llm.embed("text-embedding-3-small", input2, @valid_capabilities)

      assert length(vec1) == length(vec2)
    end
  end

  property "embed always fails without capabilities" do
    check all(input <- input_text_gen()) do
      assert {:error, {:denied, _reason}} =
               Llm.embed("text-embedding-3-small", input, [])
    end
  end

  property "every embed call produces a trace span" do
    check all(input <- input_text_gen()) do
      Trace.clear()

      Llm.embed("text-embedding-3-small", input, @valid_capabilities)

      spans = Trace.recent_spans(10)
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))
      assert length(llm_spans) >= 1
      assert hd(llm_spans).method == :embed
    end
  end

  property "same input produces same vector (deterministic test backend)" do
    check all(input <- input_text_gen()) do
      {:ok, vec1} = Llm.embed("text-embedding-3-small", input, @valid_capabilities)
      {:ok, vec2} = Llm.embed("text-embedding-3-small", input, @valid_capabilities)

      assert vec1 == vec2
    end
  end
end
