defmodule Skein.Runtime.RouterTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Router
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

    test "unknown HTTP method returns 405 without minting atoms" do
      mod =
        compile_module!("""
        module RouterUnknownMethod {
          capability http.in

          handler http GET "/hello" (req) -> {
            respond.json(200, "hi")
          }
        }
        """)

      conn = call_router(mod, "BREW", "/hello")
      assert conn.status == 405
      assert conn.resp_body =~ "Method Not Allowed"
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
    test "respond.json responses have application/json content type" do
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

    test "respond.text responses have text/plain content type" do
      mod =
        compile_module!("""
        module RouterTextHeaders {
          capability http.in

          handler http GET "/health" (req) -> {
            respond.text(200, "ok")
          }
        }
        """)

      conn = call_router(mod, :get, "/health")
      assert conn.status == 200
      assert conn.resp_body == "ok"
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "respond.html responses have text/html content type" do
      mod =
        compile_module!("""
        module RouterHtmlHeaders {
          capability http.in

          handler http GET "/page" (req) -> {
            respond.html(200, "<h1>Hello</h1>")
          }
        }
        """)

      conn = call_router(mod, :get, "/page")
      assert conn.status == 200
      assert conn.resp_body == "<h1>Hello</h1>"
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
    end
  end

  # ------------------------------------------------------------------
  # Mixed response types
  # ------------------------------------------------------------------

  describe "mixed response types" do
    test "module with all three respond types routes correctly" do
      mod =
        compile_module!("""
        module RouterMixed {
          capability http.in

          handler http GET "/api/data" (req) -> {
            respond.json(200, "data")
          }

          handler http GET "/health" (req) -> {
            respond.text(200, "ok")
          }

          handler http GET "/page" (req) -> {
            respond.html(200, "<h1>Hello</h1>")
          }
        }
        """)

      # JSON response
      conn_json = call_router(mod, :get, "/api/data")
      assert conn_json.status == 200
      assert Jason.decode!(conn_json.resp_body) == "data"
      [ct_json] = Plug.Conn.get_resp_header(conn_json, "content-type")
      assert ct_json =~ "application/json"

      # Text response
      conn_text = call_router(mod, :get, "/health")
      assert conn_text.status == 200
      assert conn_text.resp_body == "ok"
      [ct_text] = Plug.Conn.get_resp_header(conn_text, "content-type")
      assert ct_text =~ "text/plain"

      # HTML response
      conn_html = call_router(mod, :get, "/page")
      assert conn_html.status == 200
      assert conn_html.resp_body == "<h1>Hello</h1>"
      [ct_html] = Plug.Conn.get_resp_header(conn_html, "content-type")
      assert ct_html =~ "text/html"
    end

    test "respond.text with non-200 status codes" do
      mod =
        compile_module!("""
        module RouterTextStatus {
          capability http.in

          handler http GET "/not-found" (req) -> {
            respond.text(404, "not found")
          }
        }
        """)

      conn = call_router(mod, :get, "/not-found")
      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "respond.html with non-200 status codes" do
      mod =
        compile_module!("""
        module RouterHtmlStatus {
          capability http.in

          handler http GET "/error" (req) -> {
            respond.html(500, "<h1>Error</h1>")
          }
        }
        """)

      conn = call_router(mod, :get, "/error")
      assert conn.status == 500
      assert conn.resp_body == "<h1>Error</h1>"
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
