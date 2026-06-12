defmodule Skein.Runtime.Llm.BedrockBackend do
  @moduledoc """
  Amazon Bedrock LLM backend for Skein (issue #173).

  Speaks the Bedrock Converse API (`POST /model/{modelId}/converse`) —
  the uniform request shape across every Bedrock-hosted model family, so
  one backend serves Anthropic and OpenAI (and other) models. Requests
  are SigV4-signed via Req's built-in signer; STS session credentials
  are supported through the `:session_token`.

  Skein source never changes between providers — `capability
  model("anthropic", "claude-sonnet-4-6")` stays the contract, and the
  `model_map` config remaps the declared name to the Bedrock model ID or
  inference profile that serves it (e.g.
  `"global.anthropic.claude-sonnet-4-6"`). Unmapped models pass through
  unchanged.

  This is a config-tuple backend — activate it with:

      Skein.Runtime.Llm.set_backend({
        Skein.Runtime.Llm.BedrockBackend,
        %{
          region: "us-west-2",
          model_map: %{"claude-sonnet-4-6" => "global.anthropic.claude-sonnet-4-6"}
        }
      })

  In a Skein project this happens via the `[llm]` profile in skein.toml
  (`backend = "bedrock"`), resolved by `skein run`/`skein test`.

  Credentials resolve from the config map, then the standard AWS
  environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN`), then the AWS credential chain via the
  `:aws_credentials` OTP app: shared config/credentials profiles
  (`AWS_PROFILE`), EKS IRSA web-identity tokens
  (`Skein.Runtime.Llm.AwsWebIdentityProvider`), IAM Identity Center /
  SSO profiles via the `aws sso login` token cache
  (`Skein.Runtime.Llm.AwsSsoProvider`), ECS task roles, EC2 instance
  metadata (IMDSv2), and EKS Pod Identity. Chain credentials are
  cached and refreshed before they expire, and the chain only starts
  the first time it is consulted — deployments that pass explicit or
  env credentials never probe it. An expired SSO session is a
  structured error telling you to run `aws sso login --profile
  <name>`.

  `json` requests inject the schema into the system prompt (Converse has
  no schema-constrained mode that works across model families). `stream`
  calls `converse-stream` and decodes AWS's binary event-stream framing
  (`Skein.Runtime.Llm.EventStream`) into per-token text deltas;
  mid-stream exception events map to the structured `Llm.Error` kinds.
  `embed` calls InvokeModel for Titan (`amazon.titan-embed-*`)
  and Cohere (`cohere.embed-*`) embedding models.

  Model IDs go into the URL path unencoded; Req percent-encodes them in
  the SigV4 canonical request exactly as AWS does server-side. ARN-form
  model IDs (which contain `/`) cannot be represented that way, so they
  are rejected before any request with a structured error naming the
  supported alternatives (model ID or inference profile ID).
  """

  alias Skein.Runtime.Llm.AsyncBody
  alias Skein.Runtime.Llm.AwsSsoProvider
  alias Skein.Runtime.Llm.AwsWebIdentityProvider
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.EventStream
  alias Skein.Runtime.Llm.Response

  @receive_timeout 120_000
  @default_max_tokens 4096

  # The :aws_credentials chain in AWS-SDK resolution order: env vars,
  # web identity (EKS IRSA), static profile keys (AWS_PROFILE), IAM
  # Identity Center profiles (`aws sso login` token cache), ECS task
  # roles, EC2 instance metadata (IMDSv2), EKS Pod Identity. The IRSA
  # and SSO providers are ours — the library has neither.
  @chain_providers [
    :aws_credentials_env,
    AwsWebIdentityProvider,
    :aws_credentials_file,
    AwsSsoProvider,
    :aws_credentials_ecs,
    :aws_credentials_ec2,
    :aws_credentials_eks
  ]

  @typedoc """
  Backend configuration.

    * `:region` — AWS region (falls back to `AWS_REGION`)
    * `:model_map` — capability model name → Bedrock model/profile ID (optional)
    * `:access_key_id` / `:secret_access_key` / `:session_token` —
      explicit credentials; fall back to the standard AWS env vars
    * `:base_url` — endpoint override for VPC endpoints or tests (optional)
  """
  @type config :: %{
          optional(:region) => String.t(),
          optional(:model_map) => %{String.t() => String.t()},
          optional(:access_key_id) => String.t() | nil,
          optional(:secret_access_key) => String.t() | nil,
          optional(:session_token) => String.t() | nil,
          optional(:base_url) => String.t() | nil
        }

  @doc """
  Sends a Converse request to Bedrock.

  Returns `{:ok, %Response{}}` or `{:error, %Error{}}`.
  """
  @spec chat(String.t(), String.t(), any(), config()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def chat(model, system, input, config) do
    with {:ok, mapped_model} <- validated_model(model, config) do
      body = build_request_body(system, input)

      case post(config, "/model/#{mapped_model}/converse", body) do
        {:ok, response} -> build_response(response, mapped_model)
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Sends a JSON-constrained request. The schema is injected into the
  system prompt; markdown fences in the response are stripped.

  Returns `{:ok, %Response{}}` (text holds the JSON) or `{:error, %Error{}}`.
  """
  @spec json(String.t(), String.t(), any(), map(), config()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def json(model, system, input, schema, config) do
    json_system =
      system <>
        "\n\nYou MUST respond with valid JSON matching this schema. " <>
        "Output ONLY the JSON object, no markdown fences or explanation.\n\n" <>
        "Schema:\n```json\n#{Jason.encode!(schema, pretty: true)}\n```"

    with {:ok, %Response{} = resp} <- chat(model, json_system, input, config) do
      {:ok, %Response{resp | text: strip_markdown_fences(resp.text)}}
    end
  end

  @doc """
  Streams a completion via `POST /model/{modelId}/converse-stream`,
  decoding AWS's binary event-stream framing
  (`Skein.Runtime.Llm.EventStream`) into the text deltas of
  `contentBlockDelta` events. `messageStop`/`metadata` events are
  consumed; mid-stream `exception` events map to the matching
  `Llm.Error` kinds (throttling → `:rate_limit`).

  Returns `{:ok, [chunk]}` or `{:error, %Error{}}`.
  """
  @spec stream(String.t(), String.t(), any(), config()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def stream(model, system, input, config) do
    with {:ok, mapped_model} <- validated_model(model, config) do
      body = build_request_body(system, input)
      post_stream(config, "/model/#{mapped_model}/converse-stream", body)
    end
  end

  @doc """
  Generates an embedding via `POST /model/{modelId}/invoke` for Titan
  (`amazon.titan-embed-*`) and Cohere (`cohere.embed-*`) models.

  Returns `{:ok, [float()]}` or `{:error, %Error{}}`.
  """
  @spec embed(String.t(), String.t(), config()) :: {:ok, [float()]} | {:error, Error.t()}
  def embed(model, input, config) do
    with {:ok, mapped_model} <- validated_model(model, config),
         {:ok, body} <- embed_request_body(mapped_model, input),
         {:ok, response} <- post(config, "/model/#{mapped_model}/invoke", body) do
      extract_embedding(response)
    end
  end

  # -- Request building ------------------------------------------------------

  @doc false
  @spec build_request_body(String.t(), any()) :: map()
  def build_request_body(system, input) do
    user_content = if is_binary(input), do: input, else: inspect(input)

    %{
      "system" => [%{"text" => system}],
      "messages" => [%{"role" => "user", "content" => [%{"text" => user_content}]}],
      "inferenceConfig" => %{"maxTokens" => @default_max_tokens}
    }
  end

  @doc false
  @spec map_model(String.t(), config()) :: String.t()
  def map_model(model, config) do
    config |> Map.get(:model_map, %{}) |> Map.get(model, model)
  end

  # ARN-form model IDs contain `/`: sent raw, the `/` splits the URL path
  # into extra segments (Bedrock 404); pre-encoded as %2F, Req's SigV4
  # canonicalization re-encodes the `%` (signature mismatch). Reject
  # before any request with the supported alternatives (issue #180).
  @doc false
  @spec validated_model(String.t(), config()) :: {:ok, String.t()} | {:error, Error.t()}
  def validated_model(model, config) do
    mapped_model = map_model(model, config)

    if String.contains?(mapped_model, "/") do
      {:error, Error.provider_error("unsupported_model_id", arn_model_message(mapped_model))}
    else
      {:ok, mapped_model}
    end
  end

  defp arn_model_message(mapped_model) do
    base =
      "Bedrock model ID '#{mapped_model}' contains '/' (ARN-form model IDs " <>
        "cannot be represented in the SigV4-signed request path). Use the " <>
        "model ID or inference profile ID instead, mapping the capability " <>
        "model name via model_map if needed."

    case Regex.run(~r{:inference-profile/(.+)$}, mapped_model) do
      [_, profile_id] -> base <> " For this ARN, use \"#{profile_id}\"."
      nil -> base
    end
  end

  defp embed_request_body("amazon.titan-embed" <> _, input) do
    {:ok, %{"inputText" => input}}
  end

  defp embed_request_body("cohere.embed" <> _, input) do
    {:ok, %{"texts" => [input], "input_type" => "search_document"}}
  end

  defp embed_request_body(model, _input) do
    {:error,
     Error.provider_error(
       "unsupported",
       "Model '#{model}' is not a supported Bedrock embedding model. " <>
         "Use Titan (amazon.titan-embed-*) or Cohere (cohere.embed-*), " <>
         "mapping the capability model name via model_map if needed."
     )}
  end

  # -- HTTP -------------------------------------------------------------------

  @doc false
  @spec endpoint_url(config(), String.t()) :: String.t()
  def endpoint_url(%{base_url: base_url}, _region) when is_binary(base_url) and base_url != "" do
    String.trim_trailing(base_url, "/")
  end

  def endpoint_url(_config, region) do
    "https://bedrock-runtime.#{region}.amazonaws.com"
  end

  defp post(config, path, body) do
    with {:ok, credentials} <- resolve_credentials(config),
         {:ok, region} <- resolve_region(config, credentials) do
      url = endpoint_url(config, region) <> path

      case Req.post(url,
             json: body,
             aws_sigv4: sigv4_options(credentials, region),
             receive_timeout: @receive_timeout
           ) do
        {:ok, %Req.Response{status: 200, body: response_body}} ->
          {:ok, response_body}

        {:ok, %Req.Response{status: status, body: response_body} = resp} ->
          {:error, map_http_error(status, aws_error_type(resp), response_body)}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, Error.timeout(@receive_timeout)}

        {:error, exception} ->
          {:error,
           Error.provider_error(
             "transport",
             "Cannot reach Bedrock at #{url}: " <>
               redact_credentials(Exception.message(exception), credentials)
           )}
      end
    end
  end

  defp post_stream(config, path, body) do
    with {:ok, credentials} <- resolve_credentials(config),
         {:ok, region} <- resolve_region(config, credentials) do
      url = endpoint_url(config, region) <> path

      case Req.post(url,
             json: body,
             aws_sigv4: sigv4_options(credentials, region),
             receive_timeout: @receive_timeout,
             into: :self
           ) do
        {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async}} ->
          collect_event_stream(async)

        {:ok, %Req.Response{status: status} = resp} ->
          {:error, map_http_error(status, aws_error_type(resp), drained_body(resp))}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, Error.timeout(@receive_timeout)}

        {:error, exception} ->
          {:error,
           Error.provider_error(
             "transport",
             "Cannot reach Bedrock at #{url}: " <>
               redact_credentials(Exception.message(exception), credentials)
           )}
      end
    end
  end

  # Folds the event-stream frames into the chunk list: text deltas
  # accumulate, lifecycle events (messageStart/contentBlockStop/
  # messageStop/metadata) are consumed, exception events halt with the
  # mapped error. The buffer carries bytes of a frame split across
  # transport chunks.
  defp collect_event_stream(async) do
    result =
      AsyncBody.collect(async, {[], <<>>}, @receive_timeout, fn data, {chunks, buffer} ->
        case EventStream.parse_frames(buffer <> data) do
          {:ok, messages, rest} ->
            case fold_stream_messages(messages, chunks) do
              {:ok, chunks} -> {:cont, {chunks, rest}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, reason} ->
            {:halt,
             {:error,
              Error.provider_error(
                "event_stream",
                "Corrupt event-stream frame: #{inspect(reason)}"
              )}}
        end
      end)

    case result do
      {:done, {chunks, <<>>}} ->
        {:ok, Enum.reverse(chunks)}

      {:done, {_chunks, leftover}} ->
        {:error,
         Error.provider_error(
           "event_stream",
           "Truncated event stream: #{byte_size(leftover)} leftover bytes"
         )}

      {:halted, result} ->
        result

      {:stream_error, reason} ->
        {:error, Error.provider_error("stream", "Stream error: #{inspect(reason)}")}

      :timeout ->
        {:error, Error.timeout(@receive_timeout)}
    end
  end

  defp fold_stream_messages([], chunks), do: {:ok, chunks}

  defp fold_stream_messages([message | rest], chunks) do
    case stream_message_result(message) do
      {:chunk, text} -> fold_stream_messages(rest, [text | chunks])
      :skip -> fold_stream_messages(rest, chunks)
      {:error, _} = error -> error
    end
  end

  defp stream_message_result(%{
         headers: %{":message-type" => "event"} = headers,
         payload: payload
       }) do
    case headers[":event-type"] do
      "contentBlockDelta" ->
        case Jason.decode(payload) do
          {:ok, %{"delta" => %{"text" => text}}} when is_binary(text) -> {:chunk, text}
          # Non-text deltas (tool use) and undecodable payloads carry no text.
          _ -> :skip
        end

      # messageStart/contentBlockStart/contentBlockStop/messageStop/
      # metadata — stopReason and usage have no channel in the [chunk]
      # contract (parity with the other streaming backends).
      _ ->
        :skip
    end
  end

  defp stream_message_result(%{headers: %{":message-type" => "exception"} = headers} = message) do
    type = headers[":exception-type"] || "exception"
    {:error, map_stream_exception(type, exception_message(message.payload))}
  end

  defp stream_message_result(%{headers: %{":message-type" => "error"} = headers}) do
    {:error,
     Error.provider_error(
       headers[":error-code"] || "stream",
       headers[":error-message"] || "Connection-level event-stream error"
     )}
  end

  defp stream_message_result(_message), do: :skip

  defp map_stream_exception(type, message) do
    if String.downcase(type) == "throttlingexception" do
      Error.rate_limit(60_000)
    else
      Error.provider_error(type, message)
    end
  end

  defp exception_message(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> extract_error_message(decoded)
      _ -> extract_error_message(payload)
    end
  end

  # Non-200 answers to a streaming request still deliver their (JSON)
  # error body through the async mailbox — drain it so the structured
  # error carries the real message instead of an opaque struct.
  defp drained_body(%Req.Response{body: %Req.Response.Async{} = async}) do
    raw = AsyncBody.drain(async, 5_000)

    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  end

  defp drained_body(%Req.Response{body: body}), do: body

  defp sigv4_options(credentials, region) do
    base = [
      service: "bedrock",
      region: region,
      access_key_id: credentials.access_key_id,
      secret_access_key: credentials.secret_access_key
    ]

    case credentials.session_token do
      token when is_binary(token) and token != "" -> base ++ [token: token]
      _ -> base
    end
  end

  @doc false
  @spec resolve_region(config(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve_region(config, credentials \\ %{}) do
    case presence(config[:region]) || presence(System.get_env("AWS_REGION")) ||
           credentials[:region] do
      nil ->
        {:error,
         Error.provider_error(
           "missing_region",
           "AWS region not configured. Set region in the bedrock llm profile " <>
             "(skein.toml) or export AWS_REGION."
         )}

      region ->
        {:ok, region}
    end
  end

  @doc false
  @spec resolve_credentials(config()) :: {:ok, map()} | {:error, Error.t()}
  def resolve_credentials(config) do
    access_key_id =
      presence(config[:access_key_id]) || presence(System.get_env("AWS_ACCESS_KEY_ID"))

    secret_access_key =
      presence(config[:secret_access_key]) || presence(System.get_env("AWS_SECRET_ACCESS_KEY"))

    session_token =
      presence(config[:session_token]) || presence(System.get_env("AWS_SESSION_TOKEN"))

    if access_key_id && secret_access_key do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token
       }}
    else
      case chain_credentials() do
        {:ok, _} = ok ->
          ok

        :unavailable ->
          {:error, Error.provider_error("missing_credentials", missing_credentials_message())}
      end
    end
  end

  defp missing_credentials_message do
    base =
      "AWS credentials not found in the backend config, the AWS env vars " <>
        "(AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), or the credential chain " <>
        "(AWS_PROFILE files, IAM Identity Center / SSO, EKS IRSA web identity, " <>
        "ECS task roles, EC2 instance metadata)."

    case AwsSsoProvider.sso_login_hint() do
      nil ->
        base <>
          " As a fallback, run: aws configure export-credentials --format env --profile <name>"

      hint ->
        base <> " " <> hint
    end
  end

  # The chain starts on demand — only after explicit config and env vars
  # both miss — because :aws_credentials re-probes every provider every
  # 5 seconds while no credentials exist; deployments that never use the
  # chain must never pay for that.
  defp chain_credentials do
    with {:ok, _} <- ensure_chain_started(),
         %{access_key_id: access_key_id, secret_access_key: secret_access_key} = chain <-
           :aws_credentials.get_credentials() do
      {:ok,
       %{
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: presence(chain[:token]),
         region: presence(chain[:region])
       }}
    else
      _ -> :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  defp ensure_chain_started do
    if Application.get_env(:aws_credentials, :credential_providers) == nil do
      # persistent: survives the application load that follows, which
      # would otherwise reset env to the values in its .app file.
      Application.put_env(:aws_credentials, :credential_providers, @chain_providers,
        persistent: true
      )
    end

    Application.ensure_all_started(:aws_credentials)
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  # Exception messages can embed request details; never let credentials
  # through to logs or structured errors.
  defp redact_credentials(message, credentials) do
    [credentials.secret_access_key, credentials.session_token]
    |> Enum.reduce(message, fn
      secret, acc when is_binary(secret) and secret != "" ->
        String.replace(acc, secret, "[REDACTED]")

      _, acc ->
        acc
    end)
  end

  # -- Response parsing --------------------------------------------------------

  @doc false
  @spec build_response(map(), String.t()) :: {:ok, Response.t()} | {:error, Error.t()}
  def build_response(%{"output" => %{"message" => %{"content" => content}}} = raw, model)
      when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("")

    if text == "" do
      {:error, Error.refused("Empty response from Bedrock")}
    else
      {:ok,
       %Response{
         text: text,
         model: model,
         stop_reason: map_stop_reason(raw["stopReason"]),
         usage: build_usage(raw["usage"]),
         raw: raw
       }}
    end
  end

  def build_response(other, _model) do
    {:error, Error.provider_error("unexpected_format", "Unexpected response: #{inspect(other)}")}
  end

  defp map_stop_reason("end_turn"), do: :end
  defp map_stop_reason("stop_sequence"), do: :end
  defp map_stop_reason("max_tokens"), do: :max_tokens
  defp map_stop_reason("tool_use"), do: :tool_use
  defp map_stop_reason("guardrail_intervened"), do: :content_filtered
  defp map_stop_reason("content_filtered"), do: :content_filtered
  defp map_stop_reason(_), do: nil

  defp build_usage(%{"inputTokens" => input, "outputTokens" => output}) do
    %Response.Usage{input_tokens: input, output_tokens: output}
  end

  defp build_usage(_), do: nil

  defp extract_embedding(%{"embedding" => vector}) when is_list(vector), do: {:ok, vector}

  defp extract_embedding(%{"embeddings" => [vector | _]}) when is_list(vector), do: {:ok, vector}

  defp extract_embedding(%{"embeddings" => %{"float" => [vector | _]}}) when is_list(vector),
    do: {:ok, vector}

  defp extract_embedding(other) do
    {:error,
     Error.provider_error(
       "unexpected_format",
       "Unexpected embeddings response: " <> inspect(other)
     )}
  end

  # -- Error mapping ------------------------------------------------------------

  # AWS exception types arrive in the x-amzn-errortype header, sometimes
  # namespaced ("com.amazon...#ThrottlingException") or suffixed with a
  # colon-delimited URI — normalize to the bare exception name.
  defp aws_error_type(resp) do
    case Req.Response.get_header(resp, "x-amzn-errortype") do
      [value | _] ->
        value
        |> String.split("#")
        |> List.last()
        |> String.split(":")
        |> List.first()

      [] ->
        nil
    end
  end

  @doc false
  @spec map_http_error(integer(), String.t() | nil, any()) :: Error.t()
  def map_http_error(_status, "ThrottlingException", _body), do: Error.rate_limit(60_000)
  def map_http_error(429, _type, _body), do: Error.rate_limit(60_000)

  def map_http_error(status, type, body) do
    Error.provider_error(type || "#{status}", extract_error_message(body))
  end

  defp extract_error_message(%{"message" => message}) when is_binary(message), do: message
  defp extract_error_message(%{"Message" => message}) when is_binary(message), do: message
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(body), do: inspect(body)

  defp strip_markdown_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```json\s*\n?/, "")
    |> String.replace(~r/\n?```\s*$/, "")
    |> String.trim()
  end
end
