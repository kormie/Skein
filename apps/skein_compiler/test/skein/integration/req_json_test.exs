defmodule Skein.Integration.ReqJsonTest do
  use ExUnit.Case, async: true

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

    test "invalid JSON / missing required field is a clean 400, not a 500" do
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

      # Malformed JSON -> 400 (skein-testing#25), not a 500 leak.
      conn = call_router(mod, :post, "/users", "not json")
      assert conn.status == 400

      # Missing a required field -> 400 naming the field.
      conn_missing = call_router(mod, :post, "/users", ~s({"email":"a@b.com"}))
      assert conn_missing.status == 400
      assert Jason.decode!(conn_missing.resp_body)["error"] == "validation_failed"
    end

    test "enforces @one_of / @min / @max with a 400 (skein-testing#25)" do
      mod =
        compile_module!("""
        module ReqJsonConstraints {
          capability http.in

          type Order {
            status: String @one_of(["new", "paid", "shipped"])
            qty: Int @min(1) @max(100)
          }

          handler http POST "/orders" (req) -> {
            let o = req.json[Order]!
            respond.json(200, { ok: true })
          }
        }
        """)

      assert call_router(mod, :post, "/orders", ~s({"status":"new","qty":5})).status == 200
      assert call_router(mod, :post, "/orders", ~s({"status":"BOGUS","qty":5})).status == 400
      assert call_router(mod, :post, "/orders", ~s({"status":"new","qty":9999})).status == 400
    end

    test "coerces Option fields to Some/None so match works (skein-testing#32)" do
      mod =
        compile_module!("""
        module ReqJsonOption {
          capability http.in

          type Maybe {
            name: String
            note: Option[String]
          }

          handler http POST "/maybe" (req) -> {
            let body = req.json[Maybe]!
            match body.note {
              Some(s) -> respond.json(200, { name: body.name, note: s, present: true })
              None    -> respond.json(200, { name: body.name, present: false })
            }
          }
        }
        """)

      present = call_router(mod, :post, "/maybe", ~s({"name":"n1","note":"hello"}))
      assert present.status == 200
      assert Jason.decode!(present.resp_body)["present"] == true
      assert Jason.decode!(present.resp_body)["note"] == "hello"

      absent = call_router(mod, :post, "/maybe", ~s({"name":"n2"}))
      assert absent.status == 200
      assert Jason.decode!(absent.resp_body)["present"] == false
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

    test "coerces nested object-typed fields recursively (atom keys)" do
      # Regression: req.json[T] previously only atomized top-level keys, so a
      # declared nested object field came back string-keyed and crashed on
      # `body.address.city` (KeyError on :city). Nested record-typed fields
      # must coerce recursively so they read like any other field.
      mod =
        compile_module!("""
        module ReqJsonNested {
          capability http.in

          type Address {
            city: String
            zip: String
          }

          type Signup {
            email: String
            name: String
            address: Address
          }

          handler http POST "/signup" (req) -> {
            let body = req.json[Signup]!
            respond.json(200, {
              email: body.email,
              name: body.name,
              city: body.address.city,
              zip: body.address.zip
            })
          }
        }
        """)

      conn =
        call_router(
          mod,
          :post,
          "/signup",
          ~s({"email":"a@b.com","name":"Ada","address":{"city":"Lovelace","zip":"01000"}})
        )

      assert conn.status == 200
      parsed = Jason.decode!(conn.resp_body)
      assert parsed["email"] == "a@b.com"
      assert parsed["name"] == "Ada"
      assert parsed["city"] == "Lovelace"
      assert parsed["zip"] == "01000"
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
