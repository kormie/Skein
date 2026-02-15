defmodule Skein.Runtime.Llm.AnthropicBackend do
  @moduledoc """
  Production Anthropic LLM backend for Skein.

  Implements the `Skein.Runtime.Llm.Backend` behaviour using the Anthropic
  Messages API (https://api.anthropic.com/v1/messages).

  ## Configuration

  Set the API key via application config or environment variable:

      config :skein_runtime, :anthropic_api_key, "sk-ant-..."

  Or set `ANTHROPIC_API_KEY` in the environment.

  ## Model Mapping

  Any model name starting with `"gpt-"` is automatically mapped to
  `"claude-sonnet-4-20250514"`. All other model names are passed through as-is.
  """

  @behaviour Skein.Runtime.Llm.Backend

  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response

  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @default_max_tokens 4096

  # -- Public API ----------------------------------------------------------

  @doc """
  Sends a chat request to the Anthropic Messages API.

  Returns `{:ok, response_text}` or `{:error, %Error{}}`.
  """
  @impl true
  @spec chat(String.t(), String.t(), any()) :: {:ok, Response.t()} | {:error, Error.t()}
  def chat(model, system, input) do
    body = build_request_body(model, system, input, stream: false)

    case post(body) do
      {:ok, response} -> build_response(response)
      {:error, _} = error -> error
    end
  end

  @doc """
  Sends a JSON-constrained request to the Anthropic Messages API.

  Injects the JSON schema into the system prompt and parses the response as JSON.
  Returns `{:ok, parsed_map}` or `{:error, %Error{}}`.
  """
  @impl true
  @spec json(String.t(), String.t(), any(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def json(model, system, input, schema) do
    json_system =
      system <>
        "\n\nYou MUST respond with valid JSON matching this schema. " <>
        "Output ONLY the JSON object, no markdown fences or explanation.\n\n" <>
        "Schema:\n```json\n#{Jason.encode!(schema, pretty: true)}\n```"

    body = build_request_body(model, json_system, input, stream: false)

    case post(body) do
      {:ok, response} ->
        with {:ok, %Response{} = resp} <- build_response(response) do
          {:ok, %Response{resp | text: strip_markdown_fences(resp.text)}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sends a streaming request to the Anthropic Messages API.

  Collects all content_block_delta text chunks and returns them as a list.
  Returns `{:ok, [chunk]}` or `{:error, %Error{}}`.
  """
  @impl true
  @spec stream(String.t(), String.t(), any()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def stream(model, system, input) do
    body = build_request_body(model, system, input, stream: true)

    case post_stream(body) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, _} = error -> error
    end
  end

  @doc """
  Anthropic does not provide an embeddings API.

  Returns an error directing users to use a dedicated embedding provider
  (e.g., OpenAI, Voyage AI, or a local model).
  """
  @impl true
  @spec embed(String.t(), String.t()) :: {:error, Error.t()}
  def embed(_model, _input) do
    {:error,
     Error.provider_error(
       "unsupported",
       "Anthropic does not provide an embeddings API. " <>
         "Use a dedicated embedding provider such as OpenAI (text-embedding-3-small), " <>
         "Voyage AI, or a local model."
     )}
  end

  # -- Request Building ----------------------------------------------------

  @doc false
  @spec map_model(String.t()) :: String.t()
  def map_model("gpt-" <> _rest), do: "claude-sonnet-4-20250514"
  def map_model(model), do: model

  @doc false
  @spec build_request_body(String.t(), String.t(), any(), keyword()) :: map()
  def build_request_body(model, system, input, opts) do
    user_content = if is_binary(input), do: input, else: inspect(input)

    body = %{
      "model" => map_model(model),
      "max_tokens" => @default_max_tokens,
      "system" => system,
      "messages" => [
        %{"role" => "user", "content" => user_content}
      ]
    }

    if Keyword.get(opts, :stream, false) do
      Map.put(body, "stream", true)
    else
      body
    end
  end

  # -- HTTP ----------------------------------------------------------------

  @doc false
  @spec get_api_key() :: String.t() | nil
  def get_api_key do
    Application.get_env(:skein_runtime, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  defp headers do
    [
      {"x-api-key", get_api_key() || ""},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]
  end

  defp post(body) do
    case Req.post(@api_url, json: body, headers: headers(), receive_timeout: 120_000) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, map_http_error(status, response_body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout(120_000)}

      {:error, exception} ->
        {:error, Error.provider_error("transport", Exception.message(exception))}
    end
  end

  defp post_stream(body) do
    case Req.post(@api_url,
           json: body,
           headers: headers(),
           receive_timeout: 120_000,
           into: :self
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        collect_sse_chunks(resp)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, map_http_error(status, response_body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout(120_000)}

      {:error, exception} ->
        {:error, Error.provider_error("transport", Exception.message(exception))}
    end
  end

  defp collect_sse_chunks(resp) do
    collect_sse_chunks(resp, [], "")
  end

  defp collect_sse_chunks(resp, chunks, buffer) do
    ref = resp.body

    receive do
      {^ref, {:data, data}} ->
        new_buffer = buffer <> data
        {events, remaining} = parse_sse_buffer(new_buffer)
        new_chunks = extract_text_deltas(events) ++ chunks
        collect_sse_chunks(resp, new_chunks, remaining)

      {^ref, :done} ->
        # Process any remaining buffer
        {events, _} = parse_sse_buffer(buffer)
        final_chunks = extract_text_deltas(events) ++ chunks
        {:ok, Enum.reverse(final_chunks)}

      {^ref, {:error, reason}} ->
        {:error, Error.provider_error("stream", "Stream error: #{inspect(reason)}")}
    after
      120_000 ->
        {:error, Error.timeout(120_000)}
    end
  end

  # -- SSE Parsing ---------------------------------------------------------

  @doc false
  @spec parse_sse_buffer(String.t()) :: {[map()], String.t()}
  def parse_sse_buffer(buffer) do
    # Split on double newlines (SSE event boundary)
    parts = String.split(buffer, "\n\n")

    case parts do
      [single] ->
        # No complete event yet
        {[], single}

      parts ->
        # Last part is incomplete
        {complete, [remaining]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.map(&parse_sse_event/1)
          |> Enum.reject(&is_nil/1)

        {events, remaining}
    end
  end

  defp parse_sse_event(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["data", value] ->
          case Jason.decode(value) do
            {:ok, parsed} -> Map.put(acc, "data", parsed)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> case do
      %{"data" => _} = event -> event
      _ -> nil
    end
  end

  defp extract_text_deltas(events) do
    Enum.flat_map(events, fn
      %{"data" => %{"type" => "content_block_delta", "delta" => %{"text" => text}}} ->
        [text]

      _ ->
        []
    end)
  end

  # -- Response Parsing ----------------------------------------------------

  @doc false
  @spec build_response(map()) :: {:ok, Response.t()} | {:error, Error.t()}
  def build_response(%{"content" => [%{"type" => "text", "text" => text} | _]} = raw) do
    {:ok,
     %Response{
       text: text,
       model: raw["model"],
       stop_reason: map_stop_reason(raw["stop_reason"]),
       usage: build_usage(raw["usage"]),
       raw: raw
     }}
  end

  def build_response(%{"content" => []}) do
    {:error, Error.refused("Empty response from Anthropic")}
  end

  def build_response(%{"type" => "error", "error" => %{"message" => msg}}) do
    {:error, Error.provider_error("api_error", msg)}
  end

  def build_response(other) do
    {:error, Error.provider_error("unexpected_format", "Unexpected response: #{inspect(other)}")}
  end

  @doc false
  @spec extract_text(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def extract_text(%{"content" => [%{"type" => "text", "text" => text} | _]}) do
    {:ok, text}
  end

  def extract_text(%{"content" => []}) do
    {:error, Error.refused("Empty response from Anthropic")}
  end

  def extract_text(%{"type" => "error", "error" => %{"message" => msg}}) do
    {:error, Error.provider_error("api_error", msg)}
  end

  def extract_text(other) do
    {:error, Error.provider_error("unexpected_format", "Unexpected response: #{inspect(other)}")}
  end

  defp map_stop_reason("end_turn"), do: :end
  defp map_stop_reason("stop_sequence"), do: :end
  defp map_stop_reason("max_tokens"), do: :max_tokens
  defp map_stop_reason("tool_use"), do: :tool_use
  defp map_stop_reason(_), do: nil

  defp build_usage(%{"input_tokens" => input, "output_tokens" => output}) do
    %Response.Usage{input_tokens: input, output_tokens: output}
  end

  defp build_usage(_), do: nil

  # -- Error Mapping -------------------------------------------------------

  @doc false
  @spec map_http_error(integer(), any()) :: Error.t()
  def map_http_error(429, body) do
    retry_after = extract_retry_after(body)
    Error.rate_limit(retry_after)
  end

  def map_http_error(status, body) when status >= 500 do
    message = extract_error_message(body)
    Error.provider_error("#{status}", message)
  end

  def map_http_error(400, body) do
    message = extract_error_message(body)
    Error.provider_error("bad_request", message)
  end

  def map_http_error(401, _body) do
    Error.provider_error("unauthorized", "Invalid or missing API key")
  end

  def map_http_error(403, _body) do
    Error.provider_error("forbidden", "Access denied")
  end

  def map_http_error(status, body) do
    message = extract_error_message(body)
    Error.provider_error("#{status}", message)
  end

  defp extract_error_message(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(body), do: inspect(body)

  defp extract_retry_after(%{"error" => %{"message" => msg}}) do
    case Regex.run(~r/(\d+)\s*seconds?/, msg) do
      [_, seconds] -> String.to_integer(seconds) * 1000
      _ -> 60_000
    end
  end

  defp extract_retry_after(_), do: 60_000

  defp strip_markdown_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```json\s*\n?/, "")
    |> String.replace(~r/\n?```\s*$/, "")
    |> String.trim()
  end
end
