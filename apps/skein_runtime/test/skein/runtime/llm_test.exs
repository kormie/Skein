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

    test "atomizes schema-declared keys, including nested objects and arrays" do
      Llm.set_backend(Skein.Runtime.LlmTest.NestedJsonBackend)

      schema = %{
        "type" => "object",
        "required" => ["user"],
        "properties" => %{
          "user" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "tags" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "required" => ["label"],
                  "properties" => %{"label" => %{"type" => "string"}}
                }
              }
            }
          },
          "scores" => %{
            "type" => "object",
            "additionalProperties" => %{
              "type" => "object",
              "required" => ["value"],
              "properties" => %{"value" => %{"type" => "integer"}}
            }
          }
        }
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Return JSON.", "input", schema, @valid_capabilities)

      # Schema-declared field names become atoms at every nesting level.
      assert result.user.name == "Ada"
      assert [%{label: "vip"}] = result.user.tags

      # Map[K, V] keys are data, not field names — they stay strings, but
      # the value objects' declared fields atomize.
      assert %{"q1" => %{value: 10}} = result.scores

      # Keys outside the schema's closed set are left untouched (no
      # uncontrolled String.to_atom on wire data).
      assert result["extra"] == "untouched"
    end

    test "atomizes enum variant objects against their matching oneOf branch" do
      Llm.set_backend(Skein.Runtime.LlmTest.VariantJsonBackend)

      schema = %{
        "oneOf" => [
          %{
            "type" => "object",
            "properties" => %{
              "type" => %{"const" => "Charge"},
              "amount" => %{"type" => "integer"}
            },
            "required" => ["amount", "type"]
          },
          %{
            "type" => "object",
            "properties" => %{"type" => %{"const" => "Waive"}},
            "required" => ["type"]
          }
        ]
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Return JSON.", "input", schema, @valid_capabilities)

      assert result.type == "Charge"
      assert result.amount == 5
    end

    test "atomizes results parsed from raw JSON text backends" do
      Llm.set_backend(Skein.Runtime.LlmTest.RawTextJsonBackend)

      schema = %{
        "type" => "object",
        "required" => ["action"],
        "properties" => %{"action" => %{"type" => "string"}}
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Return JSON.", "input", schema, @valid_capabilities)

      assert result.action == "go"
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

  # ------------------------------------------------------------------
  # Test backend conformance / leniency (skein-testing #4, #19, #27)
  # ------------------------------------------------------------------

  describe "test backend conforms to the requested schema (#4)" do
    test "json/5 synthesizes a value shaped like T, not a fixed canned map" do
      schema = %{
        "type" => "object",
        "required" => ["action", "confidence"],
        "properties" => %{
          "action" => %{"type" => "string"},
          "confidence" => %{"type" => "integer"}
        }
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Decide", "x", schema, @valid_capabilities)

      # Declared fields are present (and atomized) regardless of name.
      assert is_binary(result.action)
      assert is_integer(result.confidence)
      assert result.confidence > 0
    end

    test "json/5 respects @one_of (enum) and @min on the schema" do
      schema = %{
        "type" => "object",
        "required" => ["decision", "score"],
        "properties" => %{
          "decision" => %{"type" => "string", "enum" => ["approve", "deny"]},
          "score" => %{"type" => "integer", "minimum" => 10}
        }
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Decide", "x", schema, @valid_capabilities)

      assert result.decision in ["approve", "deny"]
      assert result.score >= 10
    end
  end

  describe "test backend implements stream (#19)" do
    test "stream/5 assembles deterministic non-empty text offline" do
      assert {:ok, text} =
               Llm.stream(
                 "claude-sonnet-4-5",
                 "sys",
                 "hello",
                 fn _chunk -> :ok end,
                 @valid_capabilities
               )

      assert is_binary(text)
      assert String.length(text) > 0
    end
  end

  describe "lenient JSON parsing (#27)" do
    test "extracts JSON wrapped in a ```json code fence" do
      Llm.set_backend(Skein.Runtime.LlmTest.FencedJsonBackend)

      schema = %{
        "type" => "object",
        "required" => ["next"],
        "properties" => %{"next" => %{"type" => "string"}}
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Choose", "x", schema, @valid_capabilities)

      assert result.next == "fight"
    end

    test "extracts a JSON object embedded in surrounding prose" do
      Llm.set_backend(Skein.Runtime.LlmTest.ProseJsonBackend)

      schema = %{
        "type" => "object",
        "required" => ["next"],
        "properties" => %{"next" => %{"type" => "string"}}
      }

      assert {:ok, result} =
               Llm.json("claude-sonnet-4-5", "Choose", "x", schema, @valid_capabilities)

      assert result.next == "loot"
    end
  end
end

defmodule Skein.Runtime.LlmTest.NestedJsonBackend do
  @moduledoc false
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok,
     %{
       "user" => %{"name" => "Ada", "tags" => [%{"label" => "vip"}]},
       "scores" => %{"q1" => %{"value" => 10}},
       "extra" => "untouched"
     }}
  end
end

defmodule Skein.Runtime.LlmTest.VariantJsonBackend do
  @moduledoc false
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, %{"type" => "Charge", "amount" => 5}}
  end
end

defmodule Skein.Runtime.LlmTest.RawTextJsonBackend do
  @moduledoc false
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, ~s({"action": "go", "noise": true})}
  end
end

defmodule Skein.Runtime.LlmTest.FencedJsonBackend do
  @moduledoc false
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, "Here is the result:\n\n```json\n{\"next\": \"fight\"}\n```\n"}
  end
end

defmodule Skein.Runtime.LlmTest.ProseJsonBackend do
  @moduledoc false
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok,
     "I notice the instructions, but here's my answer: {\"next\": \"loot\"} — hope that helps!"}
  end
end
