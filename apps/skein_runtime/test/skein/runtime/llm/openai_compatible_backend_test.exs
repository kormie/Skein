defmodule Skein.Runtime.Llm.OpenAiCompatibleBackendTest do
  @moduledoc """
  Tests for the OpenAI-compatible backend against a stub local server —
  the inference-free CI path for local-model development (issue #107).
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.OpenAiCompatibleBackend
  alias Skein.Runtime.Llm.Response

  # A minimal OpenAI-compatible /chat/completions + /embeddings stub.
  # The test process registers itself; every request is sent back to it
  # for assertions, and the canned response comes from the plug opts.
  defmodule StubServer do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      decoded = if body == "", do: %{}, else: Jason.decode!(body)

      send(opts[:owner], {:stub_request, conn.request_path, decoded, conn.req_headers})

      {status, response} = opts[:respond].(conn.request_path, decoded)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  defp start_stub(respond) do
    port = Enum.random(10_000..60_000)

    {:ok, pid} =
      Bandit.start_link(
        plug: {StubServer, [owner: self(), respond: respond]},
        port: port,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    "http://127.0.0.1:#{port}/v1"
  end

  defp chat_completion(text, model \\ "local-model") do
    {200,
     %{
       "id" => "chatcmpl-1",
       "model" => model,
       "choices" => [
         %{
           "index" => 0,
           "message" => %{"role" => "assistant", "content" => text},
           "finish_reason" => "stop"
         }
       ],
       "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
     }}
  end

  describe "chat/4" do
    test "returns the assistant message from the local server" do
      base_url = start_stub(fn _path, _body -> chat_completion("Hello from oMLX") end)
      config = %{base_url: base_url}

      assert {:ok, %Response{} = resp} =
               OpenAiCompatibleBackend.chat("claude-opus-4-8", "Be helpful", "hi", config)

      assert resp.text == "Hello from oMLX"
      assert resp.model == "local-model"
      assert resp.stop_reason == :end
      assert resp.usage.input_tokens == 10
      assert resp.usage.output_tokens == 5

      assert_receive {:stub_request, "/v1/chat/completions", body, _headers}
      assert [%{"role" => "system"} = sys, %{"role" => "user"} = user] = body["messages"]
      assert sys["content"] == "Be helpful"
      assert user["content"] == "hi"
    end

    test "model_map remaps the capability model to the locally hosted one" do
      base_url = start_stub(fn _path, _body -> chat_completion("ok") end)

      config = %{
        base_url: base_url,
        model_map: %{"claude-opus-4-8" => "mlx-community/Qwen3-30B"}
      }

      assert {:ok, _} = OpenAiCompatibleBackend.chat("claude-opus-4-8", "sys", "hi", config)

      assert_receive {:stub_request, _, body, _}
      assert body["model"] == "mlx-community/Qwen3-30B"
    end

    test "unmapped models pass through unchanged" do
      base_url = start_stub(fn _path, _body -> chat_completion("ok") end)
      config = %{base_url: base_url, model_map: %{"other" => "mapped"}}

      assert {:ok, _} = OpenAiCompatibleBackend.chat("claude-opus-4-8", "sys", "hi", config)

      assert_receive {:stub_request, _, body, _}
      assert body["model"] == "claude-opus-4-8"
    end

    test "sends a bearer token when api_key is configured, none otherwise" do
      base_url = start_stub(fn _path, _body -> chat_completion("ok") end)

      assert {:ok, _} =
               OpenAiCompatibleBackend.chat("m", "s", "i", %{
                 base_url: base_url,
                 api_key: "secret-key"
               })

      assert_receive {:stub_request, _, _, headers}
      assert {"authorization", "Bearer secret-key"} in headers

      assert {:ok, _} = OpenAiCompatibleBackend.chat("m", "s", "i", %{base_url: base_url})
      assert_receive {:stub_request, _, _, headers2}
      refute Enum.any?(headers2, fn {name, _} -> name == "authorization" end)
    end

    test "a connection-refused error names the base_url" do
      # Nothing listens here
      config = %{base_url: "http://127.0.0.1:9/v1"}

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               OpenAiCompatibleBackend.chat("m", "s", "i", config)

      assert detail.message =~ "http://127.0.0.1:9/v1"
    end

    test "server errors map to structured provider errors" do
      base_url =
        start_stub(fn _path, _body ->
          {500, %{"error" => %{"message" => "model not loaded"}}}
        end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               OpenAiCompatibleBackend.chat("m", "s", "i", %{base_url: base_url})

      assert detail.message =~ "model not loaded"
    end
  end

  describe "json/5" do
    test "injects the schema into the system prompt and strips fences" do
      base_url =
        start_stub(fn _path, _body ->
          chat_completion("```json\n{\"action\": \"approve\"}\n```")
        end)

      schema = %{"type" => "object", "properties" => %{"action" => %{"type" => "string"}}}

      assert {:ok, %Response{text: text}} =
               OpenAiCompatibleBackend.json("m", "Decide.", "input", schema, %{
                 base_url: base_url
               })

      assert Jason.decode!(text) == %{"action" => "approve"}

      assert_receive {:stub_request, _, body, _}
      [%{"role" => "system", "content" => system} | _] = body["messages"]
      assert system =~ "Decide."
      assert system =~ "json"
    end
  end

  describe "stream/4" do
    test "returns the full completion as a single chunk" do
      base_url = start_stub(fn _path, _body -> chat_completion("streamed text") end)

      assert {:ok, ["streamed text"]} =
               OpenAiCompatibleBackend.stream("m", "s", "i", %{base_url: base_url})
    end
  end

  describe "embed/3" do
    test "returns the embedding vector from /embeddings" do
      base_url =
        start_stub(fn
          "/v1/embeddings", _body ->
            {200, %{"data" => [%{"embedding" => [0.1, 0.2, 0.3]}]}}
        end)

      assert {:ok, [0.1, 0.2, 0.3]} =
               OpenAiCompatibleBackend.embed("embed-model", "some text", %{base_url: base_url})
    end

    test "remaps the capability model name through model_map" do
      base_url =
        start_stub(fn
          "/v1/embeddings", _body ->
            {200, %{"data" => [%{"embedding" => [1.0]}]}}
        end)

      config = %{base_url: base_url, model_map: %{"voyage-3-large" => "nomic-embed-text"}}

      assert {:ok, [1.0]} = OpenAiCompatibleBackend.embed("voyage-3-large", "text", config)

      assert_receive {:stub_request, "/v1/embeddings", body, _headers}
      assert body["model"] == "nomic-embed-text"
      assert body["input"] == "text"
    end
  end

  describe "llm.embed from compiled Skein source" do
    setup do
      previous = Llm.get_backend()
      on_exit(fn -> Llm.set_backend(previous) end)
      :ok
    end

    test "returns real vectors via the stub /embeddings endpoint" do
      base_url =
        start_stub(fn
          "/v1/embeddings", _body ->
            {200, %{"data" => [%{"embedding" => [0.5, -0.25, 1.0]}]}}
        end)

      # The capability keeps the production model name; the per-environment
      # profile remaps it to the locally hosted embedding model (issue #146).
      Llm.set_backend(
        {OpenAiCompatibleBackend,
         %{base_url: base_url, model_map: %{"voyage-3-large" => "nomic-embed-text"}}}
      )

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module EmbedFlow {
          capability model("voyage", "voyage-3-large")

          fn vectorize(text: String) -> List[Float] {
            llm.embed("voyage-3-large", text)!
          }
        }
        """)

      Skein.Runtime.Trace.clear()

      assert mod.vectorize("hello world") == [0.5, -0.25, 1.0]

      assert_receive {:stub_request, "/v1/embeddings", body, _headers}
      assert body["model"] == "nomic-embed-text"
      assert body["input"] == "hello world"

      # Embed spans carry backend/base_url like chat/json/stream spans.
      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1.kind == :llm and &1.method == :embed))

      assert span != nil
      assert span.model == "voyage-3-large"
      assert span.backend == "OpenAiCompatibleBackend"
      assert span.base_url == base_url
    end
  end

  describe "through Skein.Runtime.Llm with a {module, config} backend" do
    setup do
      previous = Llm.get_backend()
      on_exit(fn -> Llm.set_backend(previous) end)
      :ok
    end

    @caps [%{kind: "model", params: ["anthropic", "claude-opus-4-8"]}]

    test "llm.chat is served by the local server with capabilities untouched" do
      base_url = start_stub(fn _path, _body -> chat_completion("local response") end)

      Llm.set_backend(
        {OpenAiCompatibleBackend,
         %{base_url: base_url, model_map: %{"claude-opus-4-8" => "qwen"}}}
      )

      assert {:ok, "local response"} = Llm.chat("claude-opus-4-8", "sys", "hi", @caps)

      assert_receive {:stub_request, _, body, _}
      assert body["model"] == "qwen"
    end

    test "llm.json is served and decoded from the local server" do
      base_url = start_stub(fn _path, _body -> chat_completion(~s({"action": "approve"})) end)
      Llm.set_backend({OpenAiCompatibleBackend, %{base_url: base_url}})

      schema = %{"type" => "object"}

      assert {:ok, %{"action" => "approve"}} =
               Llm.json("claude-opus-4-8", "sys", "hi", schema, @caps)
    end

    test "the llm trace span records backend and base_url" do
      Skein.Runtime.Trace.init()
      base_url = start_stub(fn _path, _body -> chat_completion("traced") end)
      Llm.set_backend({OpenAiCompatibleBackend, %{base_url: base_url}})

      {:ok, _} = Llm.chat("claude-opus-4-8", "sys", "hi", @caps)

      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1[:kind] == :llm and &1[:method] == :chat))

      assert span
      assert span[:backend] == "OpenAiCompatibleBackend"
      assert span[:base_url] == base_url
    end
  end
end
