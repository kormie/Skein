defmodule Skein.Runtime.Llm.AnthropicBackendTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Llm.AnthropicBackend
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response

  describe "behaviour" do
    test "implements Backend behaviour" do
      behaviours =
        AnthropicBackend.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Skein.Runtime.Llm.Backend in behaviours
    end
  end

  describe "map_model/1" do
    test "maps gpt-4 to claude-sonnet-4-20250514" do
      assert AnthropicBackend.map_model("gpt-4") == "claude-sonnet-4-20250514"
    end

    test "maps gpt-4o to claude-sonnet-4-20250514" do
      assert AnthropicBackend.map_model("gpt-4o") == "claude-sonnet-4-20250514"
    end

    test "passes through claude models" do
      assert AnthropicBackend.map_model("claude-sonnet-4-20250514") == "claude-sonnet-4-20250514"
    end

    test "passes through unknown models" do
      assert AnthropicBackend.map_model("my-custom-model") == "my-custom-model"
    end
  end

  describe "build_request_body/4" do
    test "builds correct structure" do
      body =
        AnthropicBackend.build_request_body("claude-sonnet-4-20250514", "Be helpful", "hello",
          stream: false
        )

      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["system"] == "Be helpful"
      assert body["messages"] == [%{"role" => "user", "content" => "hello"}]
      assert body["max_tokens"] == 4096
      refute Map.has_key?(body, "stream")
    end

    test "adds stream flag when streaming" do
      body =
        AnthropicBackend.build_request_body("claude-sonnet-4-20250514", "sys", "hi", stream: true)

      assert body["stream"] == true
    end

    test "maps gpt models in body" do
      body = AnthropicBackend.build_request_body("gpt-4", "sys", "hi", stream: false)
      assert body["model"] == "claude-sonnet-4-20250514"
    end

    test "inspects non-string input" do
      body =
        AnthropicBackend.build_request_body("claude-sonnet-4-20250514", "sys", %{key: "val"},
          stream: false
        )

      assert body["messages"] == [%{"role" => "user", "content" => ~s(%{key: "val"})}]
    end
  end

  describe "extract_text/1" do
    test "extracts text from valid response" do
      response = %{"content" => [%{"type" => "text", "text" => "Hello!"}]}
      assert {:ok, "Hello!"} = AnthropicBackend.extract_text(response)
    end

    test "returns error for empty content" do
      response = %{"content" => []}
      assert {:error, %Error{kind: :refused}} = AnthropicBackend.extract_text(response)
    end

    test "returns error for API error response" do
      response = %{"type" => "error", "error" => %{"message" => "bad request"}}
      assert {:error, %Error{kind: :provider_error}} = AnthropicBackend.extract_text(response)
    end

    test "returns error for unexpected format" do
      assert {:error, %Error{kind: :provider_error}} = AnthropicBackend.extract_text(%{})
    end
  end

  describe "map_http_error/2" do
    test "429 maps to rate_limit" do
      error =
        AnthropicBackend.map_http_error(429, %{"error" => %{"message" => "retry in 30 seconds"}})

      assert %Error{kind: :rate_limit, detail: %{retry_after_ms: 30_000}} = error
    end

    test "429 with no parseable retry defaults to 60s" do
      error = AnthropicBackend.map_http_error(429, %{"error" => %{"message" => "rate limited"}})
      assert %Error{kind: :rate_limit, detail: %{retry_after_ms: 60_000}} = error
    end

    test "500 maps to provider_error" do
      error = AnthropicBackend.map_http_error(500, %{"error" => %{"message" => "internal error"}})

      assert %Error{kind: :provider_error, detail: %{code: "500", message: "internal error"}} =
               error
    end

    test "503 maps to provider_error" do
      error = AnthropicBackend.map_http_error(503, %{"error" => %{"message" => "overloaded"}})
      assert %Error{kind: :provider_error, detail: %{code: "503"}} = error
    end

    test "401 maps to unauthorized" do
      error = AnthropicBackend.map_http_error(401, %{})
      assert %Error{kind: :provider_error, detail: %{code: "unauthorized"}} = error
    end

    test "400 maps to bad_request" do
      error = AnthropicBackend.map_http_error(400, %{"error" => %{"message" => "invalid model"}})

      assert %Error{
               kind: :provider_error,
               detail: %{code: "bad_request", message: "invalid model"}
             } = error
    end
  end

  describe "build_response/1" do
    test "builds Response with text, model, usage, and stop_reason" do
      raw = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      assert {:ok, %Response{} = resp} = AnthropicBackend.build_response(raw)
      assert resp.text == "Hello!"
      assert resp.model == "claude-sonnet-4-20250514"
      assert resp.stop_reason == :end
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5
      assert resp.raw == raw
    end

    test "maps stop_reason correctly" do
      base = %{"content" => [%{"type" => "text", "text" => "x"}]}

      {:ok, r1} = AnthropicBackend.build_response(Map.put(base, "stop_reason", "end_turn"))
      assert r1.stop_reason == :end

      {:ok, r2} = AnthropicBackend.build_response(Map.put(base, "stop_reason", "max_tokens"))
      assert r2.stop_reason == :max_tokens

      {:ok, r3} = AnthropicBackend.build_response(Map.put(base, "stop_reason", "stop_sequence"))
      assert r3.stop_reason == :end

      {:ok, r4} = AnthropicBackend.build_response(Map.put(base, "stop_reason", "tool_use"))
      assert r4.stop_reason == :tool_use
    end

    test "handles missing usage gracefully" do
      raw = %{"content" => [%{"type" => "text", "text" => "Hi"}]}
      {:ok, resp} = AnthropicBackend.build_response(raw)
      assert resp.usage == nil
    end

    test "returns error for empty content" do
      assert {:error, %Error{kind: :refused}} =
               AnthropicBackend.build_response(%{"content" => []})
    end
  end

  describe "embed/2" do
    test "always returns unsupported error" do
      assert {:error, %Error{kind: :provider_error, detail: %{code: "unsupported"}}} =
               AnthropicBackend.embed("claude-sonnet-4-20250514", "some text")
    end
  end

  describe "parse_sse_buffer/1" do
    test "parses complete SSE events" do
      buffer =
        ~s(data: {"type":"content_block_delta","delta":{"text":"Hi"}}\n\ndata: {"type":"content_block_delta","delta":{"text":"!"}}\n\n)

      {events, remaining} = AnthropicBackend.parse_sse_buffer(buffer)
      assert length(events) == 2
      assert remaining == ""
    end

    test "returns incomplete data as remaining" do
      buffer =
        ~s(data: {"type":"content_block_delta","delta":{"text":"Hi"}}\n\ndata: {"type":"partial)

      {events, remaining} = AnthropicBackend.parse_sse_buffer(buffer)
      assert length(events) == 1
      assert remaining =~ "partial"
    end

    test "handles empty buffer" do
      {events, remaining} = AnthropicBackend.parse_sse_buffer("")
      assert events == []
      assert remaining == ""
    end
  end
end
