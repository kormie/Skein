defmodule Skein.Runtime.Handler do
  @moduledoc """
  HTTP request dispatch for compiled Skein handler modules.

  Matches incoming requests against handler metadata from compiled modules,
  extracts route parameters, builds request maps, and dispatches to the
  appropriate handler function.

  ## Route Matching

  Routes use `:param` syntax for path parameters. For example:
  - `/users/:id` matches `/users/123` and binds `id` to `"123"`
  - `/users` matches exactly `/users`

  ## Request Map

  Handler functions receive a request map with:
  - `:params` — Map of path parameters extracted from the route
  - `:headers` — Map of request headers
  - `:body` — Raw request body string
  - `:method` — HTTP method atom (`:get`, `:post`, etc.)
  - `:path` — Request path string
  """

  alias Skein.Runtime.Trace

  @doc """
  Dispatches an HTTP request to the appropriate handler in the given module.

  Returns `{:ok, status, body, content_type}` or `{:error, reason}`.
  The `content_type` is one of `:json`, `:text`, or `:html`.
  """
  @spec dispatch(module(), atom(), String.t(), map(), String.t()) ::
          {:ok, non_neg_integer(), String.t(), :json | :text | :html} | {:error, String.t()}
  def dispatch(module, method, path, headers, body) do
    handlers = module.__handlers__()

    case find_handler(handlers, method, path) do
      {:ok, handler_info, params} ->
        Trace.with_span(
          %{kind: :handler, method: method, path: path, route: handler_info.route},
          fn ->
            req = %{
              params: params,
              headers: headers,
              body: body,
              method: method,
              path: path
            }

            handler_fn = handler_info.handler

            case apply(module, handler_fn, [req]) do
              {:respond_json, status, response_body} ->
                json_body = encode_json(response_body)
                {:ok, status, json_body, :json}

              {:respond_text, status, response_body} ->
                text_body = to_string(response_body)
                {:ok, status, text_body, :text}

              {:respond_html, status, response_body} ->
                html_body = to_string(response_body)
                {:ok, status, html_body, :html}

              other ->
                {:ok, 200, encode_json(other), :json}
            end
          end
        )

      :not_found ->
        {:error, "No handler found for #{method} #{path}"}
    end
  end

  @doc """
  Finds a matching handler for the given method and path.

  Returns `{:ok, handler_info, params}` or `:not_found`.
  """
  @spec find_handler([map()], atom(), String.t()) ::
          {:ok, map(), map()} | :not_found
  def find_handler(handlers, method, path) do
    path_segments = split_path(path)

    result =
      Enum.find_value(handlers, fn handler ->
        if handler.method == method do
          route_segments = split_path(handler.route)

          case match_route(route_segments, path_segments, %{}) do
            {:ok, params} -> {:ok, handler, params}
            :no_match -> nil
          end
        end
      end)

    result || :not_found
  end

  @doc """
  Matches a route pattern against a request path, extracting parameters.

  Returns `{:ok, params}` or `:no_match`.
  """
  @spec match_route([String.t()], [String.t()], map()) :: {:ok, map()} | :no_match
  def match_route([], [], params), do: {:ok, params}
  def match_route([], _path, _params), do: :no_match
  def match_route(_route, [], _params), do: :no_match

  def match_route([":" <> param_name | route_rest], [value | path_rest], params) do
    match_route(route_rest, path_rest, Map.put(params, String.to_atom(param_name), value))
  end

  def match_route([segment | route_rest], [segment | path_rest], params) do
    match_route(route_rest, path_rest, params)
  end

  def match_route(_route, _path, _params), do: :no_match

  # Split a path into segments, filtering out empty strings
  defp split_path(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
  end

  defp encode_json(value) when is_binary(value), do: Jason.encode!(value)
  defp encode_json(value) when is_integer(value), do: Jason.encode!(value)
  defp encode_json(value) when is_float(value), do: Jason.encode!(value)
  defp encode_json(value) when is_boolean(value), do: Jason.encode!(value)
  defp encode_json(value) when is_atom(value), do: Jason.encode!(Atom.to_string(value))
  defp encode_json(value) when is_map(value), do: Jason.encode!(value)
  defp encode_json(value) when is_list(value), do: Jason.encode!(value)
  defp encode_json(value), do: Jason.encode!(inspect(value))
end
