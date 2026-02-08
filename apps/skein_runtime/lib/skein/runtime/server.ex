defmodule Skein.Runtime.Server do
  @moduledoc """
  Lightweight HTTP server for Skein handler modules.

  Starts a TCP server that accepts HTTP requests, parses them, dispatches
  to compiled Skein handlers, and sends responses.

  Built on Erlang's `:gen_tcp` with no external dependencies. Suitable for
  development and testing — production deployments would use Bandit or Cowboy.

  ## Usage

      {:ok, pid} = Skein.Runtime.Server.start_link(
        module: Skein.User.MyService,
        port: 4000
      )

  The server will:
  1. Read `__handlers__/0` from the compiled module for route metadata
  2. Accept HTTP connections on the given port
  3. Parse requests and dispatch to handler functions
  4. Return JSON responses
  5. Serve trace data at `GET /__skein/traces`
  """

  use GenServer

  alias Skein.Runtime.Handler
  alias Skein.Runtime.Trace

  @doc """
  Starts the HTTP server.

  Options:
  - `:module` — The compiled Skein module (required)
  - `:port` — Port to listen on (default: 4000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Stops the server.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  # ------------------------------------------------------------------
  # GenServer callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    port = Keyword.get(opts, :port, 4000)

    case :gen_tcp.listen(port, [
           :binary,
           packet: :http_bin,
           active: false,
           reuseaddr: true
         ]) do
      {:ok, listen_socket} ->
        # Start accepting connections in a separate process
        acceptor = spawn_link(fn -> accept_loop(listen_socket, module) end)

        {:ok,
         %{
           module: module,
           port: port,
           listen_socket: listen_socket,
           acceptor: acceptor
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    :ok
  end

  # ------------------------------------------------------------------
  # Connection handling
  # ------------------------------------------------------------------

  defp accept_loop(listen_socket, module) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket, module) end)
        accept_loop(listen_socket, module)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_connection(socket, module) do
    case parse_request(socket) do
      {:ok, method, path, headers, body} ->
        {status, response_body, content_type} = route_request(module, method, path, headers, body)
        send_response(socket, status, response_body, content_type)

      {:error, _reason} ->
        send_response(socket, 400, ~s({"error":"Bad Request"}), "application/json")
    end

    :gen_tcp.close(socket)
  end

  defp route_request(module, method, path, headers, body) do
    # Built-in debug endpoint: GET /__skein/traces
    if method == :get and path == "/__skein/traces" do
      traces = Trace.recent_spans(50)

      traces_json =
        traces
        |> Enum.map(fn span ->
          span
          |> Map.drop([:_key])
          |> Map.update(:timestamp, nil, &to_string/1)
        end)

      {200, Jason.encode!(traces_json), "application/json"}
    else
      case Handler.dispatch(module, method, path, headers, body) do
        {:ok, status, json_body} ->
          {status, json_body, "application/json"}

        {:error, _reason} ->
          {404, ~s({"error":"Not Found"}), "application/json"}
      end
    end
  end

  # ------------------------------------------------------------------
  # HTTP request parsing
  # ------------------------------------------------------------------

  defp parse_request(socket) do
    with {:ok, {method, path}} <- read_request_line(socket),
         {:ok, headers} <- read_headers(socket, []),
         {:ok, body} <- read_body(socket, headers) do
      {:ok, method, path, Map.new(headers), body}
    end
  end

  defp read_request_line(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        method_atom =
          case method do
            :GET -> :get
            :POST -> :post
            :PUT -> :put
            :PATCH -> :patch
            :DELETE -> :delete
            other -> other
          end

        path_string = if is_list(path), do: List.to_string(path), else: path
        {:ok, {method_atom, path_string}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_header, _, field, _, value}} ->
        header_name =
          case field do
            atom when is_atom(atom) -> atom |> Atom.to_string() |> String.downcase()
            string when is_binary(string) -> String.downcase(string)
            list when is_list(list) -> list |> List.to_string() |> String.downcase()
          end

        value_string = if is_list(value), do: List.to_string(value), else: value
        read_headers(socket, [{header_name, value_string} | acc])

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body(socket, headers) do
    content_length =
      headers
      |> Enum.find_value(0, fn
        {"content-length", val} -> String.to_integer(val)
        _ -> false
      end)

    if content_length > 0 do
      # Switch to raw mode to read the body
      :inet.setopts(socket, [{:packet, :raw}])

      case :gen_tcp.recv(socket, content_length, 5000) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, ""}
    end
  end

  # ------------------------------------------------------------------
  # HTTP response sending
  # ------------------------------------------------------------------

  defp send_response(socket, status, body, content_type) do
    status_text = status_text(status)

    response = [
      "HTTP/1.1 #{status} #{status_text}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp status_text(200), do: "OK"
  defp status_text(201), do: "Created"
  defp status_text(204), do: "No Content"
  defp status_text(400), do: "Bad Request"
  defp status_text(404), do: "Not Found"
  defp status_text(500), do: "Internal Server Error"
  defp status_text(_), do: "Unknown"
end
