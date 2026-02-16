defmodule Skein.Runtime.LlmTraceTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Llm.Response
  alias Skein.Runtime.Llm.Response.Usage
  alias Skein.Runtime.Trace

  @capabilities [%{kind: "model", params: ["test-model"]}]

  setup do
    Trace.init()
    Trace.clear()
    :ok
  end

  describe "trace enrichment with old string-returning backends" do
    setup do
      Llm.set_backend(Skein.Runtime.Llm.TestBackend)
      :ok
    end

    test "chat traces include input/output metadata" do
      {:ok, _} = Llm.chat("test-model", "Be helpful", "Hello", @capabilities)
      [span] = Trace.recent_spans(1)

      assert span.kind == :llm
      assert span.method == :chat
      assert span.system == "Be helpful"
      assert span.input == "Hello"
      assert span.input_type == :text
      assert span.output =~ "Test response for:"
      assert span.outcome == :ok
      assert is_integer(span.duration_us)
    end

    test "chat traces truncate long inputs" do
      long_input = String.duplicate("x", 300)
      {:ok, _} = Llm.chat("test-model", "System", long_input, @capabilities)
      [span] = Trace.recent_spans(1)

      assert String.length(span.input) == 203  # 200 + "..."
    end

    test "chat traces work with structured input" do
      {:ok, _} = Llm.chat("test-model", "System", %{key: "value"}, @capabilities)
      [span] = Trace.recent_spans(1)

      assert span.input_type == :structured
      assert span.input =~ "key"
    end

    test "no usage/stop_reason for old backends" do
      {:ok, _} = Llm.chat("test-model", "System", "Hi", @capabilities)
      [span] = Trace.recent_spans(1)

      refute Map.has_key?(span, :usage)
      refute Map.has_key?(span, :stop_reason)
      refute Map.has_key?(span, :actual_model)
    end
  end

  describe "trace enrichment with Response-aware backends" do
    defmodule ResponseBackend do
      @behaviour Skein.Runtime.Llm.Backend

      @impl true
      def chat(_model, _system, input) do
        {:ok,
         %Response{
           text: "Response for #{input}",
           model: "actual-model-v2",
           stop_reason: :end,
           usage: %Usage{input_tokens: 23, output_tokens: 14}
         }}
      end

      @impl true
      def json(_model, _system, _input, _schema) do
        {:ok,
         %Response{
           text: ~s({"result": "ok"}),
           model: "actual-model-v2",
           stop_reason: :end,
           usage: %Usage{input_tokens: 50, output_tokens: 30}
         }}
      end
    end

    setup do
      Llm.set_backend(ResponseBackend)
      :ok
    end

    test "chat extracts text from Response and enriches trace" do
      {:ok, text} = Llm.chat("test-model", "System", "Hello", @capabilities)
      assert text == "Response for Hello"

      [span] = Trace.recent_spans(1)
      assert span.output == "Response for Hello"
      assert span.actual_model == "actual-model-v2"
      assert span.stop_reason == :end
      assert span.usage == %{input_tokens: 23, output_tokens: 14}
    end

    test "json parses JSON from Response text and enriches trace" do
      {:ok, parsed} = Llm.json("test-model", "System", "Hi", %{}, @capabilities)
      assert parsed == %{"result" => "ok"}

      [span] = Trace.recent_spans(1)
      assert span.usage == %{input_tokens: 50, output_tokens: 30}
      assert span.actual_model == "actual-model-v2"
    end
  end

  describe "error traces" do
    setup do
      Llm.set_backend(Skein.Runtime.Llm.FailingBackend)
      :ok
    end

    test "errors still record span with input metadata" do
      {:error, _} = Llm.chat("test-model", "System", "Hello", @capabilities)
      [span] = Trace.recent_spans(1)

      assert span.system == "System"
      assert span.input == "Hello"
      assert span.outcome == :error
    end
  end
end
