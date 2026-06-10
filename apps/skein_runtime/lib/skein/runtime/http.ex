defmodule Skein.Runtime.Http do
  @moduledoc """
  Runtime HTTP client for Skein effect calls.

  Wraps Erlang's `:httpc` module to make outbound HTTP requests.
  Every call is:
  1. Checked against the module's declared capabilities
  2. Traced with timing, metadata, and outcome
  3. Returns `{:ok, body}` or `{:error, reason}`

  This module is called by compiled Skein code — the codegen emits calls
  like `Skein.Runtime.Http.get(url, capabilities)`.
  """

  alias Skein.Runtime.Capability
  alias Skein.Runtime.Trace

  @doc """
  Performs an HTTP GET request.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec get(String.t(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def get(url, capabilities) when is_binary(url) and is_list(capabilities) do
    execute(:get, url, nil, capabilities)
  end

  @doc """
  Performs an HTTP POST request.

  Map bodies are JSON-encoded (requests are sent as `application/json`);
  string bodies pass through unchanged. Skein map literals compile to
  Elixir maps, so `http.post(url, { a: 1 })` lands here as a map.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec post(String.t(), String.t() | map(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def post(url, body, capabilities)
      when is_binary(url) and is_binary(body) and is_list(capabilities) do
    execute(:post, url, body, capabilities)
  end

  def post(url, body, capabilities)
      when is_binary(url) and is_map(body) and is_list(capabilities) do
    with_encoded_body(body, &execute(:post, url, &1, capabilities))
  end

  @doc """
  Performs an HTTP PUT request.

  Accepts string or map bodies like `post/3`.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec put(String.t(), String.t() | map(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def put(url, body, capabilities)
      when is_binary(url) and is_binary(body) and is_list(capabilities) do
    execute(:put, url, body, capabilities)
  end

  def put(url, body, capabilities)
      when is_binary(url) and is_map(body) and is_list(capabilities) do
    with_encoded_body(body, &execute(:put, url, &1, capabilities))
  end

  @doc """
  Performs an HTTP PATCH request.

  Accepts string or map bodies like `post/3`.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec patch(String.t(), String.t() | map(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def patch(url, body, capabilities)
      when is_binary(url) and is_binary(body) and is_list(capabilities) do
    execute(:patch, url, body, capabilities)
  end

  def patch(url, body, capabilities)
      when is_binary(url) and is_map(body) and is_list(capabilities) do
    with_encoded_body(body, &execute(:patch, url, &1, capabilities))
  end

  @doc """
  Performs an HTTP DELETE request.

  Returns `{:ok, body}` or `{:error, reason}`.
  """
  @spec delete(String.t(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def delete(url, capabilities) when is_binary(url) and is_list(capabilities) do
    execute(:delete, url, nil, capabilities)
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp with_encoded_body(body, request_fn) do
    case Jason.encode(body) do
      {:ok, json} -> request_fn.(json)
      {:error, reason} -> {:error, "Cannot encode request body as JSON: #{inspect(reason)}"}
    end
  end

  defp execute(method, url, body, capabilities) do
    Trace.with_span(%{kind: :http, method: method, url: url}, fn ->
      case Capability.check_http(url, capabilities) do
        :ok ->
          do_request(method, url, body)

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp do_request(method, url, body) do
    ensure_inets_started()
    char_url = String.to_charlist(url)

    request =
      case {method, body} do
        {m, nil} when m in [:get, :delete] ->
          {char_url, []}

        {_m, body} when is_binary(body) ->
          content_type = ~c"application/json"
          {char_url, [], content_type, String.to_charlist(body)}
      end

    http_method =
      case method do
        :patch -> :put
        other -> other
      end

    case :httpc.request(
           http_method,
           request,
           [{:timeout, 30_000}, {:connect_timeout, 10_000}],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        body_string = List.to_string(response_body)

        if status >= 200 and status < 300 do
          {:ok, body_string}
        else
          {:error, "HTTP #{status}: #{body_string}"}
        end

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp ensure_inets_started do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end

    case :ssl.start() do
      :ok -> :ok
      {:error, {:already_started, :ssl}} -> :ok
    end
  end
end
