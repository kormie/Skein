defmodule Skein.Runtime.Llm.OpenAiCompatibleBackend do
  @moduledoc """
  Generic OpenAI-compatible LLM backend for local model servers.

  Speaks the de facto local standard — `POST {base_url}/chat/completions`
  — which oMLX, Ollama, LM Studio, llama.cpp and vLLM all serve. Intended
  for development traffic so capability declarations never change between
  environments (issue #107): the `model_map` config remaps the model named
  in the `capability model(...)` declaration to whatever the local server
  hosts; unmapped models pass through unchanged.

  This is a config-tuple backend — activate it with:

      Skein.Runtime.Llm.set_backend({
        Skein.Runtime.Llm.OpenAiCompatibleBackend,
        %{
          base_url: "http://localhost:10240/v1",
          api_key: nil,                              # most local servers need none
          model_map: %{"claude-opus-4-8" => "mlx-community/Qwen3-30B"}
        }
      })

  In a Skein project this happens via the `[env.<name>.llm]` profile in
  `skein.toml`, resolved by `skein run`/`skein test`.

  `json` requests inject the schema into the system prompt (the one
  approach every local server supports; `response_format` json_schema is
  rejected by several of them). `stream` performs a regular completion and
  returns it as a single chunk — chunked SSE framing varies too much
  across local servers to rely on.
  """

  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response

  @receive_timeout 120_000

  @typedoc """
  Backend configuration.

    * `:base_url` — server base URL including any `/v1` prefix (required)
    * `:api_key` — bearer token, omitted when nil (optional)
    * `:model_map` — capability model name → locally hosted model (optional)
  """
  @type config :: %{
          required(:base_url) => String.t(),
          optional(:api_key) => String.t() | nil,
          optional(:model_map) => %{String.t() => String.t()}
        }

  @doc """
  Sends a chat completion request to the local server.

  Returns `{:ok, %Response{}}` or `{:error, %Error{}}`.
  """
  @spec chat(String.t(), String.t(), any(), config()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def chat(model, system, input, config) do
    body = build_request_body(model, system, input, config)

    case post(config, "/chat/completions", body) do
      {:ok, response} -> build_response(response)
      {:error, _} = error -> error
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
  Streams a completion. Local servers vary too much in SSE framing to
  depend on, so this performs a regular completion and returns the full
  text as a single chunk.

  Returns `{:ok, [chunk]}` or `{:error, %Error{}}`.
  """
  @spec stream(String.t(), String.t(), any(), config()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def stream(model, system, input, config) do
    case chat(model, system, input, config) do
      {:ok, %Response{text: text}} -> {:ok, [text]}
      {:error, _} = error -> error
    end
  end

  @doc """
  Generates an embedding via `POST {base_url}/embeddings`.

  Returns `{:ok, [float()]}` or `{:error, %Error{}}`.
  """
  @spec embed(String.t(), String.t(), config()) :: {:ok, [float()]} | {:error, Error.t()}
  def embed(model, input, config) do
    body = %{"model" => map_model(model, config), "input" => input}

    case post(config, "/embeddings", body) do
      {:ok, %{"data" => [%{"embedding" => vector} | _]}} when is_list(vector) ->
        {:ok, vector}

      {:ok, other} ->
        {:error,
         Error.provider_error(
           "unexpected_format",
           "Unexpected embeddings response: " <> inspect(other)
         )}

      {:error, _} = error ->
        error
    end
  end

  # -- Request building ------------------------------------------------------

  @doc false
  @spec build_request_body(String.t(), String.t(), any(), config()) :: map()
  def build_request_body(model, system, input, config) do
    user_content = if is_binary(input), do: input, else: inspect(input)

    %{
      "model" => map_model(model, config),
      "messages" => [
        %{"role" => "system", "content" => system},
        %{"role" => "user", "content" => user_content}
      ]
    }
  end

  @doc false
  @spec map_model(String.t(), config()) :: String.t()
  def map_model(model, config) do
    config |> Map.get(:model_map, %{}) |> Map.get(model, model)
  end

  # -- HTTP -------------------------------------------------------------------

  defp post(config, path, body) do
    base_url = Map.fetch!(config, :base_url)
    url = String.trim_trailing(base_url, "/") <> path

    case Req.post(url, json: body, headers: headers(config), receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, map_http_error(status, response_body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout(@receive_timeout)}

      {:error, exception} ->
        {:error,
         Error.provider_error(
           "transport",
           "Cannot reach local model server at #{base_url}: " <>
             redact_api_key(Exception.message(exception), config)
         )}
    end
  end

  defp headers(config) do
    case Map.get(config, :api_key) do
      key when is_binary(key) and key != "" ->
        [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]

      _ ->
        [{"content-type", "application/json"}]
    end
  end

  # Exception messages can embed request details; never let the API key
  # through to logs or structured errors.
  defp redact_api_key(message, config) do
    case Map.get(config, :api_key) do
      key when is_binary(key) and key != "" -> String.replace(message, key, "[REDACTED]")
      _ -> message
    end
  end

  # -- Response parsing --------------------------------------------------------

  @doc false
  @spec build_response(map()) :: {:ok, Response.t()} | {:error, Error.t()}
  def build_response(%{"choices" => [%{"message" => %{"content" => text}} = choice | _]} = raw)
      when is_binary(text) do
    {:ok,
     %Response{
       text: text,
       model: raw["model"],
       stop_reason: map_finish_reason(choice["finish_reason"]),
       usage: build_usage(raw["usage"]),
       raw: raw
     }}
  end

  def build_response(%{"choices" => []}) do
    {:error, Error.refused("Empty response from local model server")}
  end

  def build_response(%{"error" => %{"message" => message}}) do
    {:error, Error.provider_error("api_error", message)}
  end

  def build_response(other) do
    {:error, Error.provider_error("unexpected_format", "Unexpected response: #{inspect(other)}")}
  end

  defp map_finish_reason("stop"), do: :end
  defp map_finish_reason("length"), do: :max_tokens
  defp map_finish_reason("tool_calls"), do: :tool_use
  defp map_finish_reason(_), do: nil

  defp build_usage(%{"prompt_tokens" => input, "completion_tokens" => output}) do
    %Response.Usage{input_tokens: input, output_tokens: output}
  end

  defp build_usage(_), do: nil

  # -- Error mapping ------------------------------------------------------------

  defp map_http_error(429, body) do
    _ = body
    Error.rate_limit(60_000)
  end

  defp map_http_error(401, _body) do
    Error.provider_error("unauthorized", "Invalid or missing API key")
  end

  defp map_http_error(status, body) do
    Error.provider_error("#{status}", extract_error_message(body))
  end

  defp extract_error_message(%{"error" => %{"message" => message}}), do: message
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
