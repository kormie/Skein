defmodule Skein.Runtime.BanditServerTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Server
  alias Skein.Runtime.Trace

  # Helper to compile a Skein module and return the loaded module atom
  defp compile_module!(source) do
    {:ok, tokens} = Skein.Lexer.tokenize(source)
    {:ok, ast} = Skein.Parser.parse(tokens)
    analyzed = analyze_ok!(Skein.Analyzer.analyze(ast))
    {:ok, beam} = Skein.CodeGen.CoreErlang.generate(analyzed)
    module_name = String.to_atom("Elixir.Skein.User.#{ast.name}")
    {:module, mod} = :code.load_binary(module_name, ~c"nofile", beam)
    mod
  end

  defp analyze_ok!({:ok, ast}), do: ast
  defp analyze_ok!({:ok, ast, _warnings}), do: ast
  defp analyze_ok!({:error, errors}), do: raise("Compilation failed: #{inspect(errors)}")

  # Use a unique port per test to avoid conflicts
  defp unique_port do
    Enum.random(10_000..60_000)
  end

  # Helper to make HTTP requests using :httpc
  defp http_get(port, path) do
    :inets.start()
    :ssl.start()
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case :httpc.request(:get, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {status, List.to_string(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_post(port, path, body) do
    :inets.start()
    :ssl.start()
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case :httpc.request(
           :post,
           {url, [], ~c"application/json", String.to_charlist(body)},
           [{:timeout, 5000}],
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, resp_body}} ->
        {status, List.to_string(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  describe "Bandit-based server: start and serve" do
    test "starts and serves GET requests" do
      mod =
        compile_module!("""
        module BanditGetTest {
          capability http.in

          handler http GET "/hello" (req) -> {
            respond.json(200, "Hello from Bandit!")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      # Give Bandit time to start accepting
      Process.sleep(100)

      {status, body} = http_get(port, "/hello")
      assert status == 200
      assert Jason.decode!(body) == "Hello from Bandit!"

      Server.stop(pid)
    end

    test "serves POST requests" do
      mod =
        compile_module!("""
        module BanditPostTest {
          capability http.in

          handler http POST "/items" (req) -> {
            respond.json(201, "created")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status, body} = http_post(port, "/items", ~s({"name":"test"}))
      assert status == 201
      assert Jason.decode!(body) == "created"

      Server.stop(pid)
    end

    test "route params work through Bandit" do
      mod =
        compile_module!("""
        module BanditParamsTest {
          capability http.in

          handler http GET "/greet/:name" (req) -> {
            respond.json(200, "hello")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status, _body} = http_get(port, "/greet/world")
      assert status == 200

      Server.stop(pid)
    end

    test "unmatched route returns 404" do
      mod =
        compile_module!("""
        module BanditNotFound {
          capability http.in

          handler http GET "/exists" (req) -> {
            respond.json(200, "found")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status, body} = http_get(port, "/does-not-exist")
      assert status == 404
      assert body =~ "Not Found"

      Server.stop(pid)
    end

    test "multiple handlers route correctly" do
      mod =
        compile_module!("""
        module BanditMulti {
          capability http.in

          handler http GET "/a" (req) -> {
            respond.json(200, "route_a")
          }

          handler http GET "/b" (req) -> {
            respond.json(200, "route_b")
          }

          handler http POST "/a" (req) -> {
            respond.json(201, "posted_a")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status_a, body_a} = http_get(port, "/a")
      assert status_a == 200
      assert Jason.decode!(body_a) == "route_a"

      {status_b, body_b} = http_get(port, "/b")
      assert status_b == 200
      assert Jason.decode!(body_b) == "route_b"

      {status_post, body_post} = http_post(port, "/a", "")
      assert status_post == 201
      assert Jason.decode!(body_post) == "posted_a"

      Server.stop(pid)
    end

    test "handler with computation in body" do
      mod =
        compile_module!("""
        module BanditCompute {
          capability http.in

          handler http GET "/add" (req) -> {
            let result = 3 + 4
            respond.json(200, result)
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status, body} = http_get(port, "/add")
      assert status == 200
      assert Jason.decode!(body) == 7

      Server.stop(pid)
    end

    test "handler calling module function" do
      mod =
        compile_module!("""
        module BanditFnCall {
          capability http.in

          fn greeting(name: String) -> String {
            "Hello, ${name}!"
          }

          handler http GET "/greet" (req) -> {
            let msg = greeting("Skein")
            respond.json(200, msg)
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      {status, body} = http_get(port, "/greet")
      assert status == 200
      assert Jason.decode!(body) == "Hello, Skein!"

      Server.stop(pid)
    end
  end

  describe "Bandit-based server: trace endpoint" do
    test "GET /__skein/traces returns recent traces" do
      Trace.clear()

      mod =
        compile_module!("""
        module BanditTraceTest {
          capability http.in

          handler http GET "/traced" (req) -> {
            respond.json(200, "traced")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      # Make a request that will be traced
      http_get(port, "/traced")

      # Check traces endpoint
      {status, body} = http_get(port, "/__skein/traces")
      assert status == 200
      traces = Jason.decode!(body)
      assert is_list(traces)
      assert length(traces) >= 1

      Server.stop(pid)
    end
  end

  describe "Bandit-based server: concurrent requests" do
    test "handles concurrent requests correctly" do
      mod =
        compile_module!("""
        module BanditConcurrent {
          capability http.in

          handler http GET "/slow" (req) -> {
            respond.json(200, "done")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(100)

      # Launch 10 concurrent requests
      tasks =
        for _i <- 1..10 do
          Task.async(fn -> http_get(port, "/slow") end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      for {status, body} <- results do
        assert status == 200
        assert Jason.decode!(body) == "done"
      end

      Server.stop(pid)
    end
  end
end
