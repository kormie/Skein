defmodule Skein.Runtime.LlmTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "model", params: ["anthropic", "claude-sonnet-4-5"]}]
  @no_capabilities []

  setup do
    Trace.clear()
    # Reset the test backend between tests
    Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    :ok
  end

  # ------------------------------------------------------------------
  # chat/4
  # ------------------------------------------------------------------

  describe "chat/4" do
    test "returns {:ok, response} on success" do
      assert {:ok, response} =
               Llm.chat("claude-sonnet-4-5", "You are helpful.", "Hello", @valid_capabilities)

      assert is_binary(response)
    end

    test "rejects without model capability" do
      assert {:error, %Llm.Error{kind: :capability_error}} =
               Llm.chat("claude-sonnet-4-5", "system", "input", @no_capabilities)
    end

    test "records a trace span with model metadata" do
      Llm.chat("claude-sonnet-4-5", "system", "Hello", @valid_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :llm
      assert span.method == :chat
      assert span.model == "claude-sonnet-4-5"
      assert span.outcome == :ok
    end

    test "handles backend errors gracefully" do
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      assert {:error, %Llm.Error{kind: :provider_error}} =
               Llm.chat("claude-sonnet-4-5", "system", "input", @valid_capabilities)
    end
  end

  # ------------------------------------------------------------------
  # json/5
  # ------------------------------------------------------------------

  describe "json/5" do
    test "returns {:ok, parsed_map} when schema validates" do
      schema = %{
        "type" => "object",
        "required" => ["action", "amount"],
        "properties" => %{
          "action" => %{"type" => "string"},
          "amount" => %{"type" => "integer"}
        }
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Return JSON.", "input", schema, @valid_capabilities)

      assert is_map(result)
      assert Map.has_key?(result, "action") or Map.has_key?(result, :action)
    end

    test "returns parse_failed error when response is not valid JSON" do
      Llm.set_backend(Skein.Runtime.Llm.InvalidJsonBackend)

      schema = %{"type" => "object"}

      assert {:error, %Llm.Error{kind: :parse_failed}} =
               Llm.json(
                 "claude-sonnet-4-5",
                 "Return JSON.",
                 "input",
                 schema,
                 @valid_capabilities
               )
    end

    test "rejects without model capability" do
      schema = %{"type" => "object"}

      assert {:error, %Llm.Error{kind: :capability_error}} =
               Llm.json("claude-sonnet-4-5", "system", "input", schema, @no_capabilities)
    end

    test "records a trace span" do
      schema = %{"type" => "object"}
      Llm.json("claude-sonnet-4-5", "system", "input", schema, @valid_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :llm
      assert span.method == :json
    end
  end

  # ------------------------------------------------------------------
  # LlmError
  # ------------------------------------------------------------------

  describe "Llm.Error" do
    test "parse_failed error has expected fields" do
      error = Llm.Error.parse_failed("not json", "RefundDecision", "unexpected token")
      assert error.kind == :parse_failed
      assert error.detail.raw == "not json"
      assert error.detail.expected_type == "RefundDecision"
      assert error.detail.parse_error == "unexpected token"
    end

    test "refused error has reason" do
      error = Llm.Error.refused("Content policy violation")
      assert error.kind == :refused
      assert error.detail.reason == "Content policy violation"
    end

    test "rate_limit error has retry_after" do
      error = Llm.Error.rate_limit(30_000)
      assert error.kind == :rate_limit
      assert error.detail.retry_after_ms == 30_000
    end

    test "timeout error has elapsed" do
      error = Llm.Error.timeout(5_000)
      assert error.kind == :timeout
      assert error.detail.elapsed_ms == 5_000
    end

    test "content_filtered error has filter name" do
      error = Llm.Error.content_filtered("safety")
      assert error.kind == :content_filtered
      assert error.detail.filter == "safety"
    end

    test "invalid_schema error has violations list" do
      error = Llm.Error.invalid_schema(["missing field: action", "wrong type for amount"])
      assert error.kind == :invalid_schema
      assert length(error.detail.violations) == 2
    end

    test "provider_error has code and message" do
      error = Llm.Error.provider_error("500", "Internal server error")
      assert error.kind == :provider_error
      assert error.detail.code == "500"
      assert error.detail.message == "Internal server error"
    end
  end

  # ------------------------------------------------------------------
  # Backend configuration
  # ------------------------------------------------------------------

  describe "backend configuration" do
    test "set_backend/1 changes the active backend" do
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)

      assert {:error, %Llm.Error{kind: :provider_error}} =
               Llm.chat("claude-sonnet-4-5", "system", "input", @valid_capabilities)

      Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      assert {:ok, _} =
               Llm.chat("claude-sonnet-4-5", "system", "input", @valid_capabilities)
    end
  end
end
