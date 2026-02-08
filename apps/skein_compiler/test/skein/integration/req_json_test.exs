defmodule Skein.Integration.ReqJsonTest do
  use ExUnit.Case, async: true

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

  # Helper to call a handler through the Plug router
  defp call_router(mod, method, path, body) do
    router = Skein.Runtime.Router.build(mod)

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
  # req.json[T] — end-to-end with type validation
  # ------------------------------------------------------------------

  describe "req.json[T] end-to-end" do
    test "handler parses typed JSON body and uses fields" do
      mod =
        compile_module!("""
        module ReqJsonBasic {
          capability http.in

          type CreateUser {
            email: String
            name: String
          }

          handler http POST "/users" (req) -> {
            let body = req.json[CreateUser]!
            respond.json(201, body)
          }
        }
        """)

      conn = call_router(mod, :post, "/users", ~s({"email":"alice@test.com","name":"Alice"}))
      assert conn.status == 201
      parsed = Jason.decode!(conn.resp_body)
      assert parsed["email"] == "alice@test.com"
      assert parsed["name"] == "Alice"
    end

    test "handler returns error for invalid JSON body" do
      mod =
        compile_module!("""
        module ReqJsonInvalid {
          capability http.in

          type UserInput {
            email: String
            name: String
          }

          handler http POST "/users" (req) -> {
            let body = req.json[UserInput]!
            respond.json(201, body)
          }
        }
        """)

      # Send invalid JSON
      conn = call_router(mod, :post, "/users", "not json")
      # Should get a 500 or error since we used ! (unwrap-crash)
      assert conn.status == 500
    end

    test "handler with req.json[T] and ? propagation" do
      mod =
        compile_module!("""
        module ReqJsonPropagate {
          capability http.in

          type Item {
            name: String
          }

          handler http POST "/items" (req) -> {
            let item = req.json[Item]?
            respond.json(201, item)
          }
        }
        """)

      # Valid body
      conn_ok = call_router(mod, :post, "/items", ~s({"name":"Widget"}))
      assert conn_ok.status == 201
      assert Jason.decode!(conn_ok.resp_body)["name"] == "Widget"
    end

    test "handler with integer fields in type" do
      mod =
        compile_module!("""
        module ReqJsonIntFields {
          capability http.in

          type Order {
            product: String
            quantity: Int
          }

          handler http POST "/orders" (req) -> {
            let order = req.json[Order]!
            respond.json(201, order)
          }
        }
        """)

      conn = call_router(mod, :post, "/orders", ~s({"product":"Widget","quantity":5}))
      assert conn.status == 201
      parsed = Jason.decode!(conn.resp_body)
      assert parsed["product"] == "Widget"
      assert parsed["quantity"] == 5
    end
  end
end
