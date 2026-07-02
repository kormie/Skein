defmodule Skein.Runtime.Http do
  @moduledoc """
  Runtime HTTP client for Skein effect calls.

  Wraps Erlang's `:httpc` module to make outbound HTTP requests.
  Every call is:
  1. Checked against the module's declared capabilities
  2. Traced with timing, metadata, and outcome
  3. Returns `{:ok, %HttpResponse}` or `{:error, <HttpError>}`

  ## Result shape (spec §6.1)

  `http.<verb>` returns `Result[HttpResponse, HttpError]`:

  - **2xx success** (`{:ok, %{status, body, headers}}`) — `status` is the
    integer code, `headers` is a `Map[String, String]`, and `body` is the
    JSON-decoded value when the response parses as a JSON object/array,
    otherwise the raw body string. Wire keys inside `body` stay strings (they
    are arbitrary data, never interned as atoms).
  - **Non-2xx** (`{:error, {:status, code, body}}`) — the spec `HttpError`
    `Status(code, body)` variant, which the caller can `match` on to react to
    upstream 4xx/5xx instead of getting an opaque raise (skein-testing#22).
  - **Transport failure** (`{:error, error}`) — the request never produced a
    response. `error` is `:timeout` (lowered `Timeout`) or `:connection_failed`
    (lowered `ConnectionFailed`).

  This module is called by compiled Skein code — the codegen emits calls
  like `Skein.Runtime.Http.get(url, capabilities)`.
  """

  alias Skein.Runtime.Capability
  alias Skein.Runtime.CapabilityStack
  alias Skein.Runtime.LiveEffectError
  alias Skein.Runtime.Replay
  alias Skein.Runtime.TestPolicy
  alias Skein.Runtime.Trace

  @doc """
  Performs an HTTP GET request.

  Returns `{:ok, %{status, body, headers}}` or `{:error, <HttpError>}`.
  """
  @spec get(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def get(url, capabilities) when is_binary(url) and is_list(capabilities) do
    execute(:get, url, nil, capabilities)
  end

  @doc """
  Performs an HTTP POST request.

  Map bodies are JSON-encoded (requests are sent as `application/json`);
  string bodies pass through unchanged. Skein map literals compile to
  Elixir maps, so `http.post(url, { a: 1 })` lands here as a map.

  Returns `{:ok, %{status, body, headers}}` or `{:error, <HttpError>}`.
  """
  @spec post(String.t(), String.t() | map(), [map()]) :: {:ok, map()} | {:error, term()}
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

  Returns `{:ok, %{status, body, headers}}` or `{:error, <HttpError>}`.
  """
  @spec put(String.t(), String.t() | map(), [map()]) :: {:ok, map()} | {:error, term()}
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

  Returns `{:ok, %{status, body, headers}}` or `{:error, <HttpError>}`.
  """
  @spec patch(String.t(), String.t() | map(), [map()]) :: {:ok, map()} | {:error, term()}
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

  Returns `{:ok, %{status, body, headers}}` or `{:error, <HttpError>}`.
  """
  @spec delete(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def delete(url, capabilities) when is_binary(url) and is_list(capabilities) do
    execute(:delete, url, nil, capabilities)
  end

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp method_string(method), do: method |> Atom.to_string() |> String.upcase()

  # The host used as the `http.out` block scope, matching the capability check's
  # host extraction so `--allow-live http.out:<host>` lines up with declarations.
  defp host(url) do
    case Capability.extract_host(url) do
      {:ok, host} -> host
      {:error, _} -> url
    end
  end

  defp with_encoded_body(body, request_fn) do
    # Option-typed record fields are {:some, v} / :none in-language (#294);
    # on the wire they are bare values / absent keys.
    case Jason.encode(Skein.Runtime.Options.strip(body)) do
      {:ok, json} ->
        request_fn.(json)

      {:error, reason} ->
        {:error, {:invalid_request, "Cannot encode request body as JSON: #{inspect(reason)}"}}
    end
  end

  defp execute(method, url, body, capabilities) do
    Trace.with_recorded_span(%{kind: :http, method: method, url: url}, fn ->
      case Capability.check_http(url, capabilities) do
        :ok ->
          dispatch(method, url, body)

        {:error, reason} ->
          # HttpError.Denied(reason) — the frozen ABI form (C2/#297).
          {{:error, {:denied, reason}}, %{}}
      end
    end)
  end

  # Resolution order (#282): a scenario `implement` provider on the active
  # capability stack wins; then an active replay context serves recorded
  # responses; otherwise the live network. The recorded event must match the
  # live call's method and URL — divergence is a clear error.
  defp dispatch(method, url, body) do
    case CapabilityStack.resolve("http.out") do
      {:implement, provider} ->
        request = %{method: method_string(method), url: url, headers: %{}, body: body}
        {provider.(request), %{implemented: true}}

      :no_provider ->
        dispatch_replay_or_live(method, url, body)
    end
  end

  defp dispatch_replay_or_live(method, url, body) do
    case Replay.next_response(:http, %{method: method, url: url}) do
      :no_replay ->
        # Under `skein test`, an outbound request with no implement/replay is
        # blocked unless the host was explicitly allowed — raising so a program's
        # own error handling cannot swallow it and let an offline test pass.
        if TestPolicy.block_live?("http.out", host(url)) do
          raise LiveEffectError.new("http.out", host(url))
        end

        do_request(method, url, body)

      {:ok, recorded} ->
        {recorded_result(recorded), %{replayed: true}}

      :exhausted ->
        {{:error,
          {:denied, "Replay trace exhausted: no recorded http event remains for #{method} #{url}"}},
         %{replayed: true}}

      {:mismatch, message} ->
        {{:error, {:denied, message}}, %{replayed: true}}
    end
  end

  # Replayed responses reconstruct the spec Result from the recorded
  # status/body/headers: 2xx -> {:ok, HttpResponse}, non-2xx -> Err(Status).
  defp recorded_result(%{"status" => status, "response_body" => body} = recorded) do
    headers = Map.get(recorded, "response_headers", %{})
    classify_response(status, body || "", headers)
  end

  defp do_request(method, url, body) do
    ensure_inets_started()
    char_url = String.to_charlist(url)
    headers = [default_user_agent_header()]

    request =
      case {method, body} do
        {m, nil} when m in [:get, :delete] ->
          {char_url, headers}

        {_m, body} when is_binary(body) ->
          content_type = ~c"application/json"
          {char_url, headers, content_type, String.to_charlist(body)}
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
      {:ok, {{_version, status, _reason}, resp_headers, response_body}} ->
        body_string = List.to_string(response_body)
        headers_map = normalize_headers(resp_headers)
        # Status/body/headers are recorded on the span so the trace replays.
        extra = %{status: status, response_body: body_string, response_headers: headers_map}
        {classify_response(status, body_string, headers_map), extra}

      {:error, reason} ->
        {{:error, classify_transport_error(reason)}, %{}}
    end
  end

  # Map a completed response to the spec Result[HttpResponse, HttpError]:
  # a 2xx is {:ok, HttpResponse}; any other status is Err(Status(code, body))
  # (the spec §6.1 HttpError.Status variant), which the caller can match on.
  defp classify_response(status, body_string, headers) when status >= 200 and status < 300 do
    {:ok, build_response(status, body_string, headers)}
  end

  defp classify_response(status, body_string, _headers) do
    {:error, {:status, status, body_string}}
  end

  # Build the spec HttpResponse: status (Int), body (decoded JSON when the
  # payload is a JSON object/array, else the raw string), headers (Map).
  defp build_response(status, body_string, headers) do
    %{status: status, body: decode_body(body_string), headers: normalize_headers(headers)}
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> body
    end
  end

  defp decode_body(body), do: body

  # httpc returns headers as a list of {charlist, charlist}; map to a
  # String => String map. Already-normalized maps pass through (replay).
  defp normalize_headers(headers) when is_map(headers), do: headers

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(_), do: %{}

  # Map a transport-level failure to an HttpError variant atom. We keep the
  # nullary variants from the spec (Timeout / ConnectionFailed); Status is an
  # {:ok, response} concern, not a transport error.
  defp classify_transport_error(:timeout), do: :timeout
  defp classify_transport_error({:failed_connect, _}), do: :connection_failed
  defp classify_transport_error(_), do: :connection_failed

  defp default_user_agent_header do
    version =
      case :application.get_key(:skein_runtime, :vsn) do
        {:ok, vsn} -> List.to_string(vsn)
        _ -> "dev"
      end

    {~c"User-Agent", String.to_charlist("skein/#{version}")}
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
