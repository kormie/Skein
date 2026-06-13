defmodule Skein.Runtime.ServerTest do
  use ExUnit.Case

  alias Skein.Runtime.Server
  alias Skein.Runtime.Trace

  # Helper to compile a Skein module and return the loaded module atom
  defp compile_module!(source) do
    {:ok, tokens} = Skein.Lexer.tokenize(source)
    {:ok, ast} = Skein.Parser.parse(tokens)
    analyzed = analyze_ok!(Skein.Analyzer.analyze(ast))
    {:ok, [{module_name, beam} | _]} = Skein.CodeGen.CoreErlang.generate(analyzed)
    {:module, mod} = :code.load_binary(module_name, ~c"nofile", beam)
    mod
  end

  defp analyze_ok!({:ok, ast}), do: ast
  defp analyze_ok!({:ok, ast, _warnings}), do: ast
  defp analyze_ok!({:error, errors}), do: raise("Compilation failed: #{inspect(errors)}")

  # Helper to make an HTTP request to localhost:port
  defp http_request(port, method, path, body \\ "") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5000)

    method_str = method |> to_string() |> String.upcase()

    request = [
      "#{method_str} #{path} HTTP/1.1\r\n",
      "Host: localhost:#{port}\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Content-Type: application/json\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
    parse_http_response(response)
  end

  defp parse_http_response(response) do
    [header_section, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(header_section, "\r\n")
    [_, status_code | _] = String.split(status_line, " ", parts: 3)
    {String.to_integer(status_code), body}
  end

  # Use a unique port per test to avoid conflicts
  defp unique_port do
    # Use a random high port
    Enum.random(10_000..60_000)
  end

  describe "schedule handler registration" do
    test "starting a server registers its schedule handlers for auto-firing" do
      mod =
        compile_module!("""
        module ServerScheduleTest {
          capability http.in
          capability schedule.trigger("*/7 * * * *")

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler schedule "*/7 * * * *" () -> {
            respond.json(200, "tick")
          }
        }
        """)

      Skein.Runtime.Schedule.reset_all()
      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      assert "*/7 * * * *" in Skein.Runtime.Schedule.list_schedules()

      Server.stop(pid)
      Skein.Runtime.Schedule.reset_all()
    end
  end

  describe "queue and topic handler registration" do
    test "starting a server subscribes its queue handlers" do
      mod =
        compile_module!("""
        module ServerQueueReg {
          capability http.in
          capability queue.consume

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler queue "server-reg-jobs" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      Skein.Runtime.Queue.reset_all()
      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      assert "server-reg-jobs" in Skein.Runtime.Queue.list_queues()

      Server.stop(pid)
      Skein.Runtime.Queue.reset_all()
    end

    test "starting a server subscribes its topic handlers" do
      mod =
        compile_module!("""
        module ServerTopicReg {
          capability http.in
          capability topic.consume("server-reg-events")

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler topic "server-reg-events" (msg) -> {
            respond.json(200, "ok")
          }
        }
        """)

      Skein.Runtime.Topic.reset_all()
      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      assert "server-reg-events" in Skein.Runtime.Topic.list_topics()

      Server.stop(pid)
      Skein.Runtime.Topic.reset_all()
    end

    test "queue.publish dispatches to a compiled handler in a running service" do
      mod =
        compile_module!("""
        module ServerQueueDispatch {
          capability http.in
          capability queue.consume
          capability memory.kv("server_dispatch_ns")

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler queue "server-dispatch-jobs" (msg) -> {
            memory.put("seen", msg.ref)
            respond.json(200, "ok")
          }
        }
        """)

      Skein.Runtime.Queue.reset_all()
      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      Skein.Runtime.Queue.publish("server-dispatch-jobs", %{ref: "msg-1"})

      caps = [%{kind: "memory.kv", params: ["server_dispatch_ns"]}]

      await(fn ->
        Skein.Runtime.Memory.get("server_dispatch_ns", "seen", caps) == {:ok, "msg-1"}
      end)

      Server.stop(pid)
      Skein.Runtime.Queue.reset_all()
    end

    test "topic.publish dispatches to a compiled handler in a running service" do
      mod =
        compile_module!("""
        module ServerTopicDispatch {
          capability http.in
          capability topic.consume("server-dispatch-events")
          capability memory.kv("server_topic_dispatch_ns")

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler topic "server-dispatch-events" (msg) -> {
            memory.put("seen", msg.ref)
            respond.json(200, "ok")
          }
        }
        """)

      Skein.Runtime.Topic.reset_all()
      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      Skein.Runtime.Topic.publish("server-dispatch-events", %{ref: "msg-2"}, [
        %{kind: "topic.publish", params: ["server-dispatch-events"]}
      ])

      caps = [%{kind: "memory.kv", params: ["server_topic_dispatch_ns"]}]

      await(fn ->
        Skein.Runtime.Memory.get("server_topic_dispatch_ns", "seen", caps) == {:ok, "msg-2"}
      end)

      Server.stop(pid)
      Skein.Runtime.Topic.reset_all()
    end
  end

  # Poll until `fun` returns true; background dispatch is asynchronous.
  defp await(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met after polling")

      true ->
        Process.sleep(20)
        await(fun, attempts - 1)
    end
  end

  describe "multi-module routing (#21)" do
    test "mounts HTTP handlers from every module behind one server" do
      mod_a =
        compile_module!("""
        module ServerMultiA {
          capability http.in
          handler http GET "/a" (req) -> { respond.json(200, "from-a") }
        }
        """)

      mod_b =
        compile_module!("""
        module ServerMultiB {
          capability http.in
          handler http GET "/b" (req) -> { respond.json(200, "from-b") }
        }
        """)

      # A module with no HTTP handlers must not shadow the others (the
      # original bug mounted exactly one module's router, often this kind).
      mod_c =
        compile_module!("""
        module ServerMultiC {
          capability topic.consume
          handler topic "events" (msg) -> { respond.json(200, "ok") }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(modules: [mod_c, mod_a, mod_b], port: port)
      Process.sleep(50)

      assert {200, body_a} = http_request(port, :get, "/a")
      assert Jason.decode!(body_a) == "from-a"

      assert {200, body_b} = http_request(port, :get, "/b")
      assert Jason.decode!(body_b) == "from-b"

      assert {404, _} = http_request(port, :get, "/nope")

      Server.stop(pid)
    end
  end

  describe "end-to-end: compile handlers + serve HTTP" do
    test "GET handler returns JSON response" do
      mod =
        compile_module!("""
        module ServerGetTest {
          capability http.in

          handler http GET "/hello" (req) -> {
            respond.json(200, "Hello, World!")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)

      # Small delay to ensure server is ready
      Process.sleep(50)

      {status, body} = http_request(port, :get, "/hello")
      assert status == 200
      assert Jason.decode!(body) == "Hello, World!"

      Server.stop(pid)
    end

    test "POST handler returns 201 Created" do
      mod =
        compile_module!("""
        module ServerPostTest {
          capability http.in

          handler http POST "/items" (req) -> {
            respond.json(201, "created")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(50)

      {status, body} = http_request(port, :post, "/items", ~s({"name":"test"}))
      assert status == 201
      assert Jason.decode!(body) == "created"

      Server.stop(pid)
    end

    test "route params are extracted" do
      mod =
        compile_module!("""
        module ServerParamsTest {
          capability http.in

          handler http GET "/greet/:name" (req) -> {
            respond.json(200, "hello")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(50)

      {status, _body} = http_request(port, :get, "/greet/world")
      assert status == 200

      Server.stop(pid)
    end

    test "unmatched route returns 404" do
      mod =
        compile_module!("""
        module ServerNotFound {
          capability http.in

          handler http GET "/exists" (req) -> {
            respond.json(200, "found")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(50)

      {status, body} = http_request(port, :get, "/does-not-exist")
      assert status == 404
      assert body =~ "Not Found"

      Server.stop(pid)
    end

    test "multiple handlers route correctly" do
      mod =
        compile_module!("""
        module ServerMulti {
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
      Process.sleep(50)

      {status_a, body_a} = http_request(port, :get, "/a")
      assert status_a == 200
      assert Jason.decode!(body_a) == "route_a"

      {status_b, body_b} = http_request(port, :get, "/b")
      assert status_b == 200
      assert Jason.decode!(body_b) == "route_b"

      {status_post, body_post} = http_request(port, :post, "/a")
      assert status_post == 201
      assert Jason.decode!(body_post) == "posted_a"

      Server.stop(pid)
    end

    test "handler with computation in body" do
      mod =
        compile_module!("""
        module ServerCompute {
          capability http.in

          handler http GET "/add" (req) -> {
            let result = 3 + 4
            respond.json(200, result)
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(50)

      {status, body} = http_request(port, :get, "/add")
      assert status == 200
      assert Jason.decode!(body) == 7

      Server.stop(pid)
    end

    test "handler calling module function" do
      mod =
        compile_module!("""
        module ServerFnCall {
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
      Process.sleep(50)

      {status, body} = http_request(port, :get, "/greet")
      assert status == 200
      assert Jason.decode!(body) == "Hello, Skein!"

      Server.stop(pid)
    end
  end

  describe "trace endpoint" do
    test "GET /__skein/traces returns recent traces" do
      Trace.clear()

      mod =
        compile_module!("""
        module ServerTraceTest {
          capability http.in

          handler http GET "/traced" (req) -> {
            respond.json(200, "traced")
          }
        }
        """)

      port = unique_port()
      {:ok, pid} = Server.start_link(module: mod, port: port)
      Process.sleep(50)

      # Make a request that will be traced
      http_request(port, :get, "/traced")

      # Check traces endpoint
      {status, body} = http_request(port, :get, "/__skein/traces")
      assert status == 200
      traces = Jason.decode!(body)
      assert is_list(traces)
      assert length(traces) >= 1

      Server.stop(pid)
    end
  end
end
