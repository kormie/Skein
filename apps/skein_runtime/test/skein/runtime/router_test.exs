defmodule Skein.Runtime.RouterTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Router
  alias Skein.Runtime.Trace

  # Helper to compile a Skein module and return the loaded module atom
  defp compile_module!(source) do
    {:ok, tokens} = Skein.Lexer.tokenize(source)
    {:ok, ast} = Skein.Parser.parse(tokens)
    {:ok, analyzed} = Skein.Analyzer.analyze(ast)
    {:ok, beam} = Skein.CodeGen.CoreErlang.generate(analyzed)
    module_name = String.to_atom("Elixir.Skein.User.#{ast.name}")
    {:module, mod} = :code.load_binary(module_name, ~c"nofile", beam)
    mod
  end

  # Helper to build a Plug router for a compiled module and call it
  defp call_router(mod, method, path, body \\ nil) do
    router = Router.build(mod)

    conn =
      if body do
        Plug.Test.conn(method, path, body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        Plug.Test.conn(method, path)
      end

    router.call(conn, router.init([]))
  end

  # ------------------------------------------------------------------
  # Basic routing
  # ------------------------------------------------------------------

  describe "basic routing" do
    test "GET handler returns JSON response" do
      mod =
        compile_module!("""
        module RouterGetTest {
          capability http.in

          handler http GET "/hello" (req) -> {
            respond.json(200, "Hello, World!")
          }
        }
        """)

      conn = call_router(mod, :get, "/hello")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == "Hello, World!"

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "application/json; charset=utf-8"
             ]
    end

    test "POST handler returns 201 Created" do
      mod =
        compile_module!("""
        module RouterPostTest {
          capability http.in

          handler http POST "/items" (req) -> {
            respond.json(201, "created")
          }
        }
        """)

      conn = call_router(mod, :post, "/items", ~s({"name":"test"}))
      assert conn.status == 201
      assert Jason.decode!(conn.resp_body) == "created"
    end

    test "route params are extracted" do
      mod =
        compile_module!("""
        module RouterParamsTest {
          capability http.in

          handler http GET "/greet/:name" (req) -> {
            respond.json(200, "hello")
          }
        }
        """)

      conn = call_router(mod, :get, "/greet/world")
      assert conn.status == 200
    end

    test "unmatched route returns 404" do
      mod =
        compile_module!("""
        module RouterNotFound {
          capability http.in

          handler http GET "/exists" (req) -> {
            respond.json(200, "found")
          }
        }
        """)

      conn = call_router(mod, :get, "/does-not-exist")
      assert conn.status == 404
      assert conn.resp_body =~ "Not Found"
    end

    test "multiple handlers route correctly" do
      mod =
        compile_module!("""
        module RouterMulti {
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

      conn_a = call_router(mod, :get, "/a")
      assert conn_a.status == 200
      assert Jason.decode!(conn_a.resp_body) == "route_a"

      conn_b = call_router(mod, :get, "/b")
      assert conn_b.status == 200
      assert Jason.decode!(conn_b.resp_body) == "route_b"

      conn_post = call_router(mod, :post, "/a")
      assert conn_post.status == 201
      assert Jason.decode!(conn_post.resp_body) == "posted_a"
    end

    test "handler with computation in body" do
      mod =
        compile_module!("""
        module RouterCompute {
          capability http.in

          handler http GET "/add" (req) -> {
            let result = 3 + 4
            respond.json(200, result)
          }
        }
        """)

      conn = call_router(mod, :get, "/add")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == 7
    end

    test "handler calling module function" do
      mod =
        compile_module!("""
        module RouterFnCall {
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

      conn = call_router(mod, :get, "/greet")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == "Hello, Skein!"
    end
  end

  # ------------------------------------------------------------------
  # Trace endpoint
  # ------------------------------------------------------------------

  describe "/__skein/traces endpoint" do
    test "GET /__skein/traces returns recent traces as JSON" do
      Trace.clear()

      mod =
        compile_module!("""
        module RouterTraceTest {
          capability http.in

          handler http GET "/traced" (req) -> {
            respond.json(200, "traced")
          }
        }
        """)

      # Make a request that will be traced
      call_router(mod, :get, "/traced")

      # Check traces endpoint
      conn = call_router(mod, :get, "/__skein/traces")
      assert conn.status == 200
      traces = Jason.decode!(conn.resp_body)
      assert is_list(traces)
      assert length(traces) >= 1
    end

    test "trace endpoint is not affected by handler definitions" do
      Trace.clear()

      mod =
        compile_module!("""
        module RouterTraceNoHandlers {
          capability http.in

          handler http POST "/only-post" (req) -> {
            respond.json(201, "posted")
          }
        }
        """)

      # Trace endpoint should work even when only POST handlers exist
      conn = call_router(mod, :get, "/__skein/traces")
      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body))
    end
  end

  # ------------------------------------------------------------------
  # Content-type handling
  # ------------------------------------------------------------------

  describe "response headers" do
    test "responses have application/json content type" do
      mod =
        compile_module!("""
        module RouterHeaders {
          capability http.in

          handler http GET "/json" (req) -> {
            respond.json(200, "ok")
          }
        }
        """)

      conn = call_router(mod, :get, "/json")
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end
  end

  # ------------------------------------------------------------------
  # Request body access
  # ------------------------------------------------------------------

  describe "request body" do
    test "POST handler receives request body" do
      mod =
        compile_module!("""
        module RouterBody {
          capability http.in

          handler http POST "/echo" (req) -> {
            respond.json(200, "received")
          }
        }
        """)

      conn = call_router(mod, :post, "/echo", ~s({"data":"test"}))
      assert conn.status == 200
    end
  end
end
