defmodule Skein.Runtime.Router do
  @moduledoc """
  Plug-based HTTP router for compiled Skein handler modules.

  Builds a Plug pipeline that:
  1. Serves the `/__skein/traces` debug endpoint
  2. Dispatches requests to compiled Skein handlers
  3. Returns 404 for unmatched routes

  ## Usage

      # Build a router module for a compiled Skein module
      router = Skein.Runtime.Router.build(MySkeinModule)

      # Use with Bandit
      Bandit.start_link(plug: router, port: 4000)

      # Or test directly with Plug.Test
      conn = Plug.Test.conn(:get, "/hello")
      conn = router.call(conn, router.init([]))
  """

  require Logger

  alias Skein.Runtime.Handler
  alias Skein.Runtime.Trace

  @doc """
  Builds a Plug module that routes requests to the given Skein module's handlers.

  Returns a module that implements the Plug behaviour, suitable for passing
  to `Bandit.start_link/1` or calling directly in tests.
  """
  @spec build(module()) :: module()
  def build(skein_module) do
    # Generate a unique router module name based on the Skein module
    router_name =
      Module.concat([Skein.Runtime.Router, Generated, skein_module])

    # If already defined, purge and redefine to pick up changes
    if :code.is_loaded(router_name) do
      :code.purge(router_name)
      :code.delete(router_name)
    end

    contents =
      quote do
        @behaviour Plug

        @impl true
        def init(opts), do: opts

        @impl true
        def call(conn, _opts) do
          Skein.Runtime.Router.dispatch(conn, unquote(skein_module))
        end
      end

    Module.create(router_name, contents, Macro.Env.location(__ENV__))
    router_name
  end

  @doc """
  Builds a Plug module that routes across several Skein modules.

  A multi-module `skein run` mounts every module's HTTP handlers behind a
  single server: each request is tried against the modules in order and
  the first one with a matching route handles it (skein-testing#21).
  """
  @spec build_multi([module()]) :: module()
  def build_multi(skein_modules) do
    router_name =
      Module.concat([
        Skein.Runtime.Router,
        Generated,
        Multi,
        :"M#{:erlang.phash2(skein_modules)}"
      ])

    if :code.is_loaded(router_name) do
      :code.purge(router_name)
      :code.delete(router_name)
    end

    contents =
      quote do
        @behaviour Plug

        @impl true
        def init(opts), do: opts

        @impl true
        def call(conn, _opts) do
          Skein.Runtime.Router.dispatch_multi(conn, unquote(skein_modules))
        end
      end

    Module.create(router_name, contents, Macro.Env.location(__ENV__))
    router_name
  end

  @doc """
  Dispatches a `Plug.Conn` to the appropriate Skein handler or built-in endpoint.

  This is the core routing function called by generated router modules.
  """
  @spec dispatch(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def dispatch(conn, skein_module) do
    dispatch_multi(conn, [skein_module])
  end

  @doc """
  Dispatches a `Plug.Conn` across a list of Skein modules, trying each in
  order until one has a matching route.
  """
  @spec dispatch_multi(Plug.Conn.t(), [module()]) :: Plug.Conn.t()
  def dispatch_multi(conn, skein_modules) do
    conn = read_body_if_needed(conn)

    if conn.method == "GET" and conn.request_path == "/__skein/traces" do
      serve_traces(conn)
    else
      dispatch_handler(conn, skein_modules)
    end
  end

  # ------------------------------------------------------------------
  # Trace endpoint
  # ------------------------------------------------------------------

  defp serve_traces(conn) do
    traces = Trace.recent_spans(50)

    traces_json =
      traces
      |> Enum.map(fn span ->
        span
        |> Map.drop([:_key])
        |> Map.update(:timestamp, nil, &to_string/1)
      end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(Skein.Runtime.Options.strip(traces_json)))
  end

  # ------------------------------------------------------------------
  # Handler dispatch
  # ------------------------------------------------------------------

  defp dispatch_handler(conn, skein_modules) do
    case method_atom(conn.method) do
      {:ok, method} ->
        path = conn.request_path
        headers = Map.new(conn.req_headers)
        body = conn.assigns[:raw_body] || ""

        attempt_modules(conn, skein_modules, method, path, headers, body)

      :error ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(405, ~s({"error":"Method Not Allowed"}))
    end
  end

  # Try each module in turn; the first matching route wins. A non-matching
  # module returns {:error, _} and we fall through to the next. Only when no
  # module matches do we 404.
  defp attempt_modules(conn, [], _method, _path, _headers, _body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(404, ~s({"error":"Not Found"}))
  end

  defp attempt_modules(conn, [skein_module | rest], method, path, headers, body) do
    try do
      case Handler.dispatch(skein_module, method, path, headers, body) do
        {:ok, status, resp_body, content_type} ->
          conn
          |> Plug.Conn.put_resp_content_type(content_type_string(content_type))
          |> Plug.Conn.send_resp(status, resp_body)

        {:error, _reason} ->
          attempt_modules(conn, rest, method, path, headers, body)
      end
    rescue
      exception ->
        Logger.error(
          "Skein handler crashed for #{conn.method} #{path}: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error":"Internal Server Error"}))
    end
  end

  defp content_type_string(:json), do: "application/json"
  defp content_type_string(:text), do: "text/plain"
  defp content_type_string(:html), do: "text/html"

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp read_body_if_needed(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        Plug.Conn.assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        # For now, we don't handle chunked bodies
        Logger.warning("Skein router: request body exceeded read limit; treating body as empty")
        Plug.Conn.assign(conn, :raw_body, "")

      {:error, reason} ->
        Logger.warning("Skein router: failed to read request body: #{inspect(reason)}")
        Plug.Conn.assign(conn, :raw_body, "")
    end
  end

  # Only whitelisted methods are converted to atoms. The method string comes
  # straight off the wire, so an open-ended String.to_atom/1 here would let
  # any client exhaust the atom table.
  defp method_atom("GET"), do: {:ok, :get}
  defp method_atom("POST"), do: {:ok, :post}
  defp method_atom("PUT"), do: {:ok, :put}
  defp method_atom("PATCH"), do: {:ok, :patch}
  defp method_atom("DELETE"), do: {:ok, :delete}
  defp method_atom("HEAD"), do: {:ok, :head}
  defp method_atom("OPTIONS"), do: {:ok, :options}
  defp method_atom(_other), do: :error
end
