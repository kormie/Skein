defmodule Skein.Runtime.Llm.BedrockBackendTest do
  @moduledoc """
  Tests for the Amazon Bedrock backend against a stub Converse server —
  the inference-free CI path for Bedrock deployments (issue #173).
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Llm.BedrockBackend
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response

  # A minimal Bedrock runtime stub serving /model/{id}/converse and
  # /model/{id}/invoke. The test process registers itself; every request
  # is sent back to it for assertions, and the canned response (status,
  # extra headers, body) comes from the plug opts.
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

      {status, headers, response} =
        case opts[:respond].(conn.request_path, decoded) do
          {status, response} -> {status, [], response}
          {status, headers, response} -> {status, headers, response}
        end

      conn
      |> put_resp_content_type("application/json")
      |> then(
        &Enum.reduce(headers, &1, fn {name, value}, c -> put_resp_header(c, name, value) end)
      )
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

    "http://127.0.0.1:#{port}"
  end

  defp config(base_url, overrides \\ %{}) do
    Map.merge(
      %{
        base_url: base_url,
        region: "us-west-2",
        access_key_id: "AKIATESTKEY",
        secret_access_key: "test-secret",
        session_token: "test-session-token"
      },
      overrides
    )
  end

  defp converse_response(text, stop_reason \\ "end_turn") do
    {200,
     %{
       "output" => %{
         "message" => %{
           "role" => "assistant",
           "content" => [%{"text" => text}]
         }
       },
       "stopReason" => stop_reason,
       "usage" => %{"inputTokens" => 12, "outputTokens" => 7, "totalTokens" => 19}
     }}
  end

  describe "chat/4" do
    test "returns the normalized response from Converse" do
      base_url = start_stub(fn _path, _body -> converse_response("Hello from Bedrock") end)

      assert {:ok, %Response{} = resp} =
               BedrockBackend.chat("claude-sonnet-4-6", "Be helpful", "hi", config(base_url))

      assert resp.text == "Hello from Bedrock"
      assert resp.model == "claude-sonnet-4-6"
      assert resp.stop_reason == :end
      assert resp.usage.input_tokens == 12
      assert resp.usage.output_tokens == 7

      assert_receive {:stub_request, "/model/claude-sonnet-4-6/converse", body, _headers}
      assert body["system"] == [%{"text" => "Be helpful"}]
      assert [%{"role" => "user", "content" => [%{"text" => "hi"}]}] = body["messages"]
      assert %{"maxTokens" => _} = body["inferenceConfig"]
    end

    test "model_map remaps the capability model to a Bedrock inference profile" do
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)

      config =
        config(base_url, %{
          model_map: %{"claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6"}
        })

      assert {:ok, %Response{model: "global.anthropic.claude-sonnet-4-6"}} =
               BedrockBackend.chat("claude-sonnet-4-6", "sys", "hi", config)

      assert_receive {:stub_request, path, _body, _headers}
      assert path == "/model/global.anthropic.claude-sonnet-4-6/converse"
    end

    test "requests are SigV4-signed with the session token included" do
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)

      assert {:ok, _} = BedrockBackend.chat("m", "s", "i", config(base_url))

      assert_receive {:stub_request, _, _, headers}
      headers = Map.new(headers)

      assert headers["authorization"] =~ "AWS4-HMAC-SHA256"
      assert headers["authorization"] =~ "Credential=AKIATESTKEY/"
      assert headers["authorization"] =~ "/us-west-2/bedrock/aws4_request"
      assert headers["x-amz-security-token"] == "test-session-token"
      assert is_binary(headers["x-amz-date"])
    end

    test "credentials fall back to the standard AWS environment variables" do
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)

      previous =
        for name <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN) do
          {name, System.get_env(name)}
        end

      on_exit(fn ->
        for {name, value} <- previous do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      System.put_env("AWS_ACCESS_KEY_ID", "AKIAFROMENV")
      System.put_env("AWS_SECRET_ACCESS_KEY", "env-secret")
      System.delete_env("AWS_SESSION_TOKEN")

      config = %{base_url: base_url, region: "us-west-2"}

      assert {:ok, _} = BedrockBackend.chat("m", "s", "i", config)

      assert_receive {:stub_request, _, _, headers}
      headers = Map.new(headers)
      assert headers["authorization"] =~ "Credential=AKIAFROMENV/"
      refute Map.has_key?(headers, "x-amz-security-token")
    end

    test "missing credentials are a structured error before any request is made" do
      previous =
        for name <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN) do
          {name, System.get_env(name)}
        end

      on_exit(fn ->
        for {name, value} <- previous do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      for {name, _} <- previous, do: System.delete_env(name)

      base_url = start_stub(fn _path, _body -> converse_response("never reached") end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url, region: "us-west-2"})

      assert detail.message =~ "AWS_ACCESS_KEY_ID"
      refute_receive {:stub_request, _, _, _}
    end

    test "a missing region is a structured error" do
      previous = System.get_env("AWS_REGION")

      on_exit(fn ->
        if previous,
          do: System.put_env("AWS_REGION", previous),
          else: System.delete_env("AWS_REGION")
      end)

      System.delete_env("AWS_REGION")

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", %{access_key_id: "k", secret_access_key: "s"})

      assert detail.message =~ "region"
    end

    test "throttling maps to a rate_limit error" do
      base_url =
        start_stub(fn _path, _body ->
          {429, [{"x-amzn-errortype", "ThrottlingException"}],
           %{"message" => "Too many requests, please wait."}}
        end)

      assert {:error, %Error{kind: :rate_limit}} =
               BedrockBackend.chat("m", "s", "i", config(base_url))
    end

    test "AWS exception types are carried as structured provider errors" do
      base_url =
        start_stub(fn _path, _body ->
          {403, [{"x-amzn-errortype", "ExpiredTokenException:"}],
           %{"message" => "The security token included in the request is expired"}}
        end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", config(base_url))

      assert detail.code == "ExpiredTokenException"
      assert detail.message =~ "expired"
    end

    test "guardrail-filtered responses surface as content_filtered stop reason" do
      base_url =
        start_stub(fn _path, _body -> converse_response("[redacted]", "guardrail_intervened") end)

      assert {:ok, %Response{stop_reason: :content_filtered}} =
               BedrockBackend.chat("m", "s", "i", config(base_url))
    end

    test "a connection-refused error names the endpoint" do
      config = config("http://127.0.0.1:9")

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", config)

      assert detail.message =~ "http://127.0.0.1:9"
    end
  end

  describe "endpoint_url/2" do
    test "defaults to the regional bedrock-runtime endpoint" do
      assert BedrockBackend.endpoint_url(%{}, "us-west-2") ==
               "https://bedrock-runtime.us-west-2.amazonaws.com"
    end

    test "an explicit base_url (VPC endpoint) wins" do
      assert BedrockBackend.endpoint_url(%{base_url: "https://vpce.example.com/"}, "us-west-2") ==
               "https://vpce.example.com"
    end
  end

  describe "json/5" do
    test "injects the schema into the system prompt and strips fences" do
      base_url =
        start_stub(fn _path, _body ->
          converse_response("```json\n{\"action\": \"approve\"}\n```")
        end)

      schema = %{"type" => "object", "properties" => %{"action" => %{"type" => "string"}}}

      assert {:ok, %Response{text: text}} =
               BedrockBackend.json("m", "Decide.", "input", schema, config(base_url))

      assert Jason.decode!(text) == %{"action" => "approve"}

      assert_receive {:stub_request, _, body, _}
      assert [%{"text" => system}] = body["system"]
      assert system =~ "Decide."
      assert system =~ "json"
    end
  end

  describe "stream/4" do
    test "returns the full completion as a single chunk" do
      base_url = start_stub(fn _path, _body -> converse_response("streamed text") end)

      assert {:ok, ["streamed text"]} =
               BedrockBackend.stream("m", "s", "i", config(base_url))
    end
  end

  describe "embed/3" do
    test "Titan models go through InvokeModel with inputText" do
      base_url =
        start_stub(fn _path, _body ->
          {200, %{"embedding" => [0.1, 0.2, 0.3], "inputTextTokenCount" => 3}}
        end)

      assert {:ok, [0.1, 0.2, 0.3]} =
               BedrockBackend.embed("amazon.titan-embed-text-v2:0", "some text", config(base_url))

      assert_receive {:stub_request, path, body, _}
      assert path == "/model/amazon.titan-embed-text-v2:0/invoke"
      assert body == %{"inputText" => "some text"}
    end

    test "Cohere models go through InvokeModel with texts" do
      base_url =
        start_stub(fn _path, _body ->
          {200, %{"embeddings" => [[1.0, 2.0]]}}
        end)

      assert {:ok, [1.0, 2.0]} =
               BedrockBackend.embed("cohere.embed-english-v3", "text", config(base_url))

      assert_receive {:stub_request, _, body, _}
      assert body["texts"] == ["text"]
    end

    test "model_map applies before family detection" do
      base_url =
        start_stub(fn _path, _body ->
          {200, %{"embedding" => [1.0]}}
        end)

      config =
        config(base_url, %{model_map: %{"voyage-3-large" => "amazon.titan-embed-text-v2:0"}})

      assert {:ok, [1.0]} = BedrockBackend.embed("voyage-3-large", "text", config)

      assert_receive {:stub_request, "/model/amazon.titan-embed-text-v2:0/invoke", _, _}
    end

    test "unsupported model families are a structured error" do
      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.embed(
                 "anthropic.claude-sonnet-4-6",
                 "text",
                 config("http://unused")
               )

      assert detail.message =~ "embedding"
    end
  end

  describe "through Skein.Runtime.Llm with a {module, config} backend" do
    setup do
      previous = Llm.get_backend()
      on_exit(fn -> Llm.set_backend(previous) end)
      :ok
    end

    @caps [%{kind: "model", params: ["anthropic", "claude-sonnet-4-6"]}]

    test "llm.chat is served by Bedrock with capabilities untouched" do
      base_url = start_stub(fn _path, _body -> converse_response("bedrock response") end)

      Llm.set_backend(
        {BedrockBackend,
         config(base_url, %{
           model_map: %{"claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6"}
         })}
      )

      assert {:ok, "bedrock response"} = Llm.chat("claude-sonnet-4-6", "sys", "hi", @caps)

      assert_receive {:stub_request, path, _, _}
      assert path == "/model/global.anthropic.claude-sonnet-4-6/converse"
    end

    test "llm.json is served and decoded from Bedrock" do
      base_url = start_stub(fn _path, _body -> converse_response(~s({"action": "approve"})) end)
      Llm.set_backend({BedrockBackend, config(base_url)})

      schema = %{"type" => "object"}

      assert {:ok, %{"action" => "approve"}} =
               Llm.json("claude-sonnet-4-6", "sys", "hi", schema, @caps)
    end

    test "the llm trace span records the backend" do
      Skein.Runtime.Trace.init()
      base_url = start_stub(fn _path, _body -> converse_response("traced") end)
      Llm.set_backend({BedrockBackend, config(base_url)})

      {:ok, _} = Llm.chat("claude-sonnet-4-6", "sys", "hi", @caps)

      span =
        Skein.Runtime.Trace.recent_spans(10)
        |> Enum.find(&(&1[:kind] == :llm and &1[:method] == :chat))

      assert span
      assert span[:backend] == "BedrockBackend"
    end
  end
end
