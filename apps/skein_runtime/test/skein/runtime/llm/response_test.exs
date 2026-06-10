defmodule Skein.Runtime.Llm.ResponseTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Llm.Response
  alias Skein.Runtime.Llm.Response.Usage

  describe "struct" do
    test "creates with defaults" do
      resp = %Response{}
      assert resp.text == nil
      assert resp.usage == nil
      assert resp.model == nil
      assert resp.stop_reason == nil
      assert resp.raw == nil
    end

    test "creates with all fields" do
      resp = %Response{
        text: "Hello",
        usage: %Usage{input_tokens: 10, output_tokens: 5},
        model: "claude-opus-4-8",
        stop_reason: :end,
        raw: %{"id" => "msg_123"}
      }

      assert resp.text == "Hello"
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5
      assert resp.model == "claude-opus-4-8"
      assert resp.stop_reason == :end
    end
  end

  describe "Usage struct" do
    test "defaults to zero tokens" do
      usage = %Usage{}
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
    end
  end

  describe "truncate/2" do
    test "returns nil for nil input" do
      assert Response.truncate(nil, 100) == nil
    end

    test "returns short strings unchanged" do
      assert Response.truncate("hello", 200) == "hello"
    end

    test "truncates long strings with ellipsis" do
      long = String.duplicate("a", 300)
      result = Response.truncate(long, 200)
      # 200 + "..."
      assert String.length(result) == 203
      assert String.ends_with?(result, "...")
    end

    test "handles exact length" do
      exact = String.duplicate("a", 200)
      assert Response.truncate(exact, 200) == exact
    end

    test "truncates at length + 1" do
      over = String.duplicate("a", 201)
      result = Response.truncate(over, 200)
      assert String.starts_with?(result, String.duplicate("a", 200))
      assert String.ends_with?(result, "...")
    end
  end
end
