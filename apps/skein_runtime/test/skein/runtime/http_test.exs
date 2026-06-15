defmodule Skein.Runtime.HttpTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Http
  alias Skein.Runtime.Trace

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Capability enforcement
  # ------------------------------------------------------------------

  describe "capability enforcement" do
    test "get/2 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.get("https://api.blocked.com/data", capabilities)
      assert reason =~ "not declared"
    end

    test "post/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.post("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "put/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.put("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "patch/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.patch("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "delete/2 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.delete("https://api.blocked.com/data", capabilities)
      assert reason =~ "not declared"
    end

    test "get/2 with no capabilities blocks all requests" do
      assert {:error, _} = Http.get("https://api.example.com/data", [])
    end

    test "post/3 accepts a map body and JSON-encodes it" do
      # Spec section 8.4 implement blocks pass map literals to http.post.
      # Capability is denied, so this never reaches the network — the map
      # body must survive to the capability check instead of crashing on
      # the binary guard.
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]

      assert {:error, reason} =
               Http.post("https://api.blocked.com/data", %{query: "ai", n: 1}, capabilities)

      assert reason =~ "not declared"
    end

    test "put/3 and patch/3 accept map bodies" do
      capabilities = []

      assert {:error, reason} = Http.put("https://api.example.com/x", %{a: 1}, capabilities)
      assert reason =~ "not declared"

      assert {:error, reason} = Http.patch("https://api.example.com/x", %{a: 1}, capabilities)
      assert reason =~ "not declared"
    end

    test "post/3 reports unencodable map bodies as errors" do
      capabilities = [%{kind: "http.out", params: []}]

      assert {:error, reason} =
               Http.post("https://api.example.com/x", %{bad: {:ok, "tuple"}}, capabilities)

      assert reason =~ "JSON"
    end

    test "get/2 with wildcard capability allows any host" do
      # Wildcard = http.out with no params
      capabilities = [%{kind: "http.out", params: []}]
      # This will likely fail to connect but should not be blocked by capability check
      result = Http.get("https://api.example.com/data", capabilities)
      # The result will be either {:ok, _} or {:error, _} from the HTTP call,
      # but NOT a capability error. A transport failure is now an HttpError
      # variant atom (:timeout / :connection_failed), not a string.
      case result do
        {:error, reason} when is_binary(reason) -> refute reason =~ "not declared"
        {:error, reason} when is_atom(reason) -> assert reason in [:timeout, :connection_failed]
        {:ok, %{status: status}} -> assert is_integer(status)
      end
    end
  end

  # ------------------------------------------------------------------
  # Response shape (spec §6.1 HttpResponse)
  # ------------------------------------------------------------------

  describe "response shape" do
    test "a 2xx response returns {:ok, %{status, body, headers}} with a decoded JSON body" do
      port = serve_once(200, ~s({"hero":"Gandalf","level":20}), [])
      caps = [%{kind: "http.out", params: []}]

      assert {:ok, response} = Http.get("http://localhost:#{port}/hero", caps)
      assert response.status == 200
      assert response.body == %{"hero" => "Gandalf", "level" => 20}
      assert is_map(response.headers)
    end

    test "a non-2xx response is Err(Status(code, body)) the caller can match on" do
      port = serve_once(503, "upstream down", [])
      caps = [%{kind: "http.out", params: []}]

      assert {:error, {:status, 503, "upstream down"}} =
               Http.get("http://localhost:#{port}/x", caps)
    end

    test "a non-JSON body is returned as the raw string" do
      port = serve_once(200, "plain text", [])
      caps = [%{kind: "http.out", params: []}]

      assert {:ok, %{status: 200, body: "plain text"}} =
               Http.get("http://localhost:#{port}/t", caps)
    end

    test "outbound requests carry a default User-Agent header" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()

      Task.start(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:request, request})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
        )

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

      caps = [%{kind: "http.out", params: []}]
      assert {:ok, %{status: 200}} = Http.get("http://localhost:#{port}/ua", caps)

      assert_receive {:request, request}, 5_000
      assert String.downcase(request) =~ "user-agent: skein/"
    end
  end

  # A minimal one-shot HTTP/1.1 server; returns the listening port.
  defp serve_once(status, body, _opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    Task.start(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      response =
        "HTTP/1.1 #{status} STATUS\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end

  # ------------------------------------------------------------------
  # Trace recording
  # ------------------------------------------------------------------

  describe "trace recording" do
    test "blocked request records a trace span" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :http
      assert span.method == :get
      assert span.outcome == :error
    end

    test "trace span includes URL" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      [span] = Trace.recent_spans(1)
      assert span.url == "https://api.blocked.com/data"
    end

    test "trace span includes timing" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      [span] = Trace.recent_spans(1)
      assert is_integer(span.duration_us)
      assert span.duration_us >= 0
    end
  end
end
