defmodule Skein.Runtime.Llm.BedrockBackendTest do
  @moduledoc """
  Tests for the Amazon Bedrock backend against a stub Converse server —
  the inference-free CI path for Bedrock deployments (issue #173).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  # The credential-chain tests start/stop :aws_credentials, which logs
  # lifecycle notices; keep them out of the suite output.
  @moduletag capture_log: true

  alias Skein.Runtime.Llm
  alias Skein.Runtime.Llm.BedrockBackend
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.EventStream
  alias Skein.Runtime.Llm.Response

  # A minimal Bedrock runtime stub serving /model/{id}/converse,
  # /model/{id}/converse-stream, and /model/{id}/invoke. The test
  # process registers itself; every request is sent back to it for
  # assertions, and the canned response — `{status[, headers], json}`
  # or `{:stream, binary_chunks}` for chunked event-stream bodies —
  # comes from the plug opts.
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

      case opts[:respond].(conn.request_path, decoded) do
        {:stream, chunks} ->
          conn =
            conn
            |> put_resp_content_type("application/vnd.amazon.eventstream")
            |> send_chunked(200)

          Enum.reduce(chunks, conn, fn data, c ->
            {:ok, c} = chunk(c, data)
            c
          end)

        {status, response} ->
          json_response(conn, status, [], response)

        {status, headers, response} ->
          json_response(conn, status, headers, response)
      end
    end

    defp json_response(conn, status, headers, response) do
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

  # A canned :aws_credentials chain provider: returns whatever the
  # provider_options carry under :chain_stub, so each test controls the
  # chain's outcome through the library's own configuration surface.
  defmodule ChainStubProvider do
    @behaviour :aws_credentials_provider

    @impl true
    def fetch(%{chain_stub: result}), do: result
    def fetch(_options), do: {:error, :no_chain_stub}
  end

  @aws_env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION)

  defp clear_aws_env do
    previous = Enum.map(@aws_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    Enum.each(@aws_env, &System.delete_env/1)
  end

  # Pins the :aws_credentials chain to the given providers for one test.
  # The app restarts on the next chain consult (resolve_credentials
  # starts it on demand) and is stopped again on exit so no cached
  # credentials leak across tests.
  defp configure_chain(providers, provider_options) do
    Application.stop(:aws_credentials)
    Application.put_env(:aws_credentials, :credential_providers, providers, persistent: true)
    Application.put_env(:aws_credentials, :provider_options, provider_options, persistent: true)

    on_exit(fn ->
      Application.stop(:aws_credentials)
      Application.delete_env(:aws_credentials, :credential_providers, persistent: true)
      Application.delete_env(:aws_credentials, :provider_options, persistent: true)
    end)
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
      clear_aws_env()
      # Pin the credential chain empty so the test cannot pick up real
      # credentials from ~/.aws or instance metadata on a dev machine.
      configure_chain([], %{})

      base_url = start_stub(fn _path, _body -> converse_response("never reached") end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url, region: "us-west-2"})

      assert detail.message =~ "AWS_ACCESS_KEY_ID"
      assert detail.message =~ "credential chain"
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

  describe "credential chain" do
    test "chain credentials serve requests when config and env vars miss" do
      clear_aws_env()
      base_url = start_stub(fn _path, _body -> converse_response("chained") end)

      creds =
        :aws_credentials.make_map(ChainStubProvider, "AKIACHAIN", "chain-secret", "chain-token")

      configure_chain([ChainStubProvider], %{chain_stub: {:ok, creds, :infinity}})

      assert {:ok, %Response{text: "chained"}} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url, region: "us-west-2"})

      assert_receive {:stub_request, _, _, headers}
      headers = Map.new(headers)
      assert headers["authorization"] =~ "Credential=AKIACHAIN/"
      assert headers["x-amz-security-token"] == "chain-token"
    end

    test "explicit config credentials win over the chain" do
      clear_aws_env()
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)
      creds = :aws_credentials.make_map(ChainStubProvider, "AKIACHAIN", "chain-secret")
      configure_chain([ChainStubProvider], %{chain_stub: {:ok, creds, :infinity}})

      assert {:ok, _} = BedrockBackend.chat("m", "s", "i", config(base_url))

      assert_receive {:stub_request, _, _, headers}
      assert Map.new(headers)["authorization"] =~ "Credential=AKIATESTKEY/"
    end

    test "chain credentials without a session token omit the security-token header" do
      clear_aws_env()
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)
      creds = :aws_credentials.make_map(ChainStubProvider, "AKIACHAIN", "chain-secret")
      configure_chain([ChainStubProvider], %{chain_stub: {:ok, creds, :infinity}})

      assert {:ok, _} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url, region: "us-west-2"})

      assert_receive {:stub_request, _, _, headers}
      refute Map.new(headers) |> Map.has_key?("x-amz-security-token")
    end

    test "the chain's region fills in when config and AWS_REGION are absent" do
      clear_aws_env()
      base_url = start_stub(fn _path, _body -> converse_response("ok") end)

      creds =
        :aws_credentials.make_map(
          ChainStubProvider,
          "AKIACHAIN",
          "chain-secret",
          "chain-token",
          "eu-central-1"
        )

      configure_chain([ChainStubProvider], %{chain_stub: {:ok, creds, :infinity}})

      assert {:ok, _} = BedrockBackend.chat("m", "s", "i", %{base_url: base_url})

      assert_receive {:stub_request, _, _, headers}
      assert Map.new(headers)["authorization"] =~ "/eu-central-1/bedrock/aws4_request"
    end

    test "a chain provider error falls through to the structured error" do
      clear_aws_env()
      configure_chain([ChainStubProvider], %{chain_stub: {:error, :boom}})

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", %{
                 base_url: "http://unused",
                 region: "us-east-1"
               })

      assert detail.code == "missing_credentials"
    end
  end

  describe "ARN-form model IDs" do
    @profile_arn "arn:aws:bedrock:us-west-2:123456789012:inference-profile/global.anthropic.claude-sonnet-4-6"

    test "are rejected before any request with the supported alternatives" do
      base_url = start_stub(fn _path, _body -> converse_response("never reached") end)
      config = config(base_url, %{model_map: %{"claude-sonnet-4-6" => @profile_arn}})

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("claude-sonnet-4-6", "s", "i", config)

      assert detail.code == "unsupported_model_id"
      assert detail.message =~ "model_map"
      refute_receive {:stub_request, _, _, _}
    end

    test "an inference-profile ARN names its profile ID as the fix" do
      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat(@profile_arn, "s", "i", config("http://unused"))

      assert detail.message =~ ~s("global.anthropic.claude-sonnet-4-6")
    end

    test "stream rejects ARNs the same way" do
      assert {:error, %Error{kind: :provider_error, detail: %{code: "unsupported_model_id"}}} =
               BedrockBackend.stream(@profile_arn, "s", "i", config("http://unused"))
    end

    test "embed rejects ARNs without an inference-profile hint" do
      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.embed(
                 "arn:aws:bedrock:us-west-2:123456789012:provisioned-model/abc123",
                 "text",
                 config("http://unused")
               )

      assert detail.code == "unsupported_model_id"
      refute detail.message =~ "For this ARN"
    end

    test "json rejects ARNs via the chat path" do
      assert {:error, %Error{kind: :provider_error, detail: %{code: "unsupported_model_id"}}} =
               BedrockBackend.json(
                 @profile_arn,
                 "s",
                 "i",
                 %{"type" => "object"},
                 config("http://unused")
               )
    end

    property "model IDs pass through validation exactly when they contain no slash" do
      check all(id <- StreamData.string(:printable, min_length: 1)) do
        case BedrockBackend.validated_model(id, %{}) do
          {:ok, ^id} ->
            refute String.contains?(id, "/")

          {:error, %Error{detail: %{code: "unsupported_model_id"}}} ->
            assert String.contains?(id, "/")
        end
      end
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

  # -- converse-stream helpers -------------------------------------------------

  defp event_frame(event_type, payload) do
    EventStream.encode_message(
      %{
        ":message-type" => "event",
        ":event-type" => event_type,
        ":content-type" => "application/json"
      },
      Jason.encode!(payload)
    )
  end

  defp exception_frame(exception_type, message) do
    EventStream.encode_message(
      %{
        ":message-type" => "exception",
        ":exception-type" => exception_type,
        ":content-type" => "application/json"
      },
      Jason.encode!(%{"message" => message})
    )
  end

  defp delta_frame(text) do
    event_frame("contentBlockDelta", %{"delta" => %{"text" => text}, "contentBlockIndex" => 0})
  end

  defp converse_stream_frames(texts) do
    [event_frame("messageStart", %{"role" => "assistant"})] ++
      Enum.map(texts, &delta_frame/1) ++
      [
        event_frame("contentBlockStop", %{"contentBlockIndex" => 0}),
        event_frame("messageStop", %{"stopReason" => "end_turn"}),
        event_frame("metadata", %{"usage" => %{"inputTokens" => 5, "outputTokens" => 7}})
      ]
  end

  describe "stream/4 (converse-stream)" do
    test "delivers the text deltas from the event stream" do
      frames = converse_stream_frames(["Hel", "lo ", "Bedrock"])
      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      assert {:ok, ["Hel", "lo ", "Bedrock"]} =
               BedrockBackend.stream("m", "s", "i", config(base_url))

      assert_receive {:stub_request, "/model/m/converse-stream", body, headers}
      assert body["system"] == [%{"text" => "s"}]
      assert Map.new(headers)["authorization"] =~ "AWS4-HMAC-SHA256"
    end

    test "model_map remaps the model on the converse-stream path" do
      frames = converse_stream_frames(["ok"])
      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      config =
        config(base_url, %{
          model_map: %{"claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6"}
        })

      assert {:ok, ["ok"]} = BedrockBackend.stream("claude-sonnet-4-6", "s", "i", config)

      assert_receive {:stub_request, path, _, _}
      assert path == "/model/global.anthropic.claude-sonnet-4-6/converse-stream"
    end

    test "frames split across transport chunks reassemble" do
      frames_binary = IO.iodata_to_binary(converse_stream_frames(["alpha", "beta"]))
      split_at = div(byte_size(frames_binary), 2) + 3
      <<first::binary-size(split_at), second::binary>> = frames_binary

      base_url = start_stub(fn _path, _body -> {:stream, [first, second]} end)

      assert {:ok, ["alpha", "beta"]} = BedrockBackend.stream("m", "s", "i", config(base_url))
    end

    test "non-text deltas are skipped without losing text chunks" do
      frames = [
        event_frame("messageStart", %{"role" => "assistant"}),
        event_frame("contentBlockDelta", %{
          "delta" => %{"toolUse" => %{"input" => "{}"}},
          "contentBlockIndex" => 0
        }),
        delta_frame("text"),
        event_frame("messageStop", %{"stopReason" => "tool_use"})
      ]

      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      assert {:ok, ["text"]} = BedrockBackend.stream("m", "s", "i", config(base_url))
    end

    test "an empty completion streams zero chunks" do
      frames = converse_stream_frames([])
      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      assert {:ok, []} = BedrockBackend.stream("m", "s", "i", config(base_url))
    end

    test "a mid-stream throttling exception maps to rate_limit" do
      frames = [
        event_frame("messageStart", %{"role" => "assistant"}),
        delta_frame("par"),
        exception_frame("throttlingException", "Too many tokens, slow down.")
      ]

      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      assert {:error, %Error{kind: :rate_limit}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))
    end

    test "other mid-stream exceptions carry their AWS type" do
      frames = [delta_frame("par"), exception_frame("modelStreamErrorException", "stream broke")]
      base_url = start_stub(fn _path, _body -> {:stream, frames} end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))

      assert detail.code == "modelStreamErrorException"
      assert detail.message == "stream broke"
    end

    test "an upfront non-200 maps through the AWS error type header" do
      base_url =
        start_stub(fn _path, _body ->
          {400, [{"x-amzn-errortype", "ValidationException"}],
           %{"message" => "The provided model identifier is invalid."}}
        end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))

      assert detail.code == "ValidationException"
      assert detail.message =~ "model identifier"
    end

    test "an upfront 429 maps to rate_limit" do
      base_url =
        start_stub(fn _path, _body ->
          {429, [{"x-amzn-errortype", "ThrottlingException"}], %{"message" => "Slow down."}}
        end)

      assert {:error, %Error{kind: :rate_limit}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))
    end

    test "a corrupt frame is a structured event_stream error" do
      frame = delta_frame("x")
      body_size = byte_size(frame) - 4
      <<body::binary-size(body_size), crc::32>> = frame
      corrupted = <<body::binary, crc + 1::32>>

      base_url = start_stub(fn _path, _body -> {:stream, [corrupted]} end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))

      assert detail.code == "event_stream"
      assert detail.message =~ "message_crc_mismatch"
    end

    test "a truncated stream is a structured event_stream error" do
      frame = delta_frame("x")
      truncated = binary_part(frame, 0, byte_size(frame) - 3)

      base_url = start_stub(fn _path, _body -> {:stream, [truncated]} end)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.stream("m", "s", "i", config(base_url))

      assert detail.code == "event_stream"
      assert detail.message =~ "Truncated"
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

    test "llm.stream delivers each token delta through the on_chunk callback" do
      frames = converse_stream_frames(["Hel", "lo ", "Bedrock"])
      base_url = start_stub(fn _path, _body -> {:stream, frames} end)
      Llm.set_backend({BedrockBackend, config(base_url)})

      owner = self()
      on_chunk = fn chunk -> send(owner, {:chunk, chunk}) end

      assert {:ok, "Hello Bedrock"} =
               Llm.stream("claude-sonnet-4-6", "sys", "hi", on_chunk, @caps)

      assert_receive {:chunk, "Hel"}
      assert_receive {:chunk, "lo "}
      assert_receive {:chunk, "Bedrock"}
      refute_receive {:chunk, _}
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
