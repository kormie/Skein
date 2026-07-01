defmodule Skein.Integration.RecordOptionBoundariesTest do
  @moduledoc """
  Uniform Option representation at serialization boundaries (#294 / B5).

  In-language, optional record fields are always `{:some, v}` / `:none`
  (total records). On the JSON wire they are bare values / absent keys.
  These tests prove the two conversions are inverses: a handler response
  strips tags, and `req.json[T]` decode re-tags — so a decoded record is
  indistinguishable from a constructed one.
  """
  use ExUnit.Case, async: true

  alias Skein.Compiler
  alias Skein.Runtime.Handler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  describe "respond.json strips Option tags onto the wire" do
    setup do
      mod =
        compile!("""
        module Api {
          capability http.in

          type User {
            name: String
            nickname: Option[String]
          }

          handler http GET "/with" (req) -> {
            respond.json(200, User { name: "ada", nickname: "Bob" })
          }

          handler http GET "/without" (req) -> {
            respond.json(200, User { name: "ada" })
          }
        }
        """)

      {:ok, mod: mod}
    end

    test "a Some field encodes as the bare value", %{mod: mod} do
      assert {:ok, 200, body, :json} = Handler.dispatch(mod, :get, "/with", [], "")
      assert Jason.decode!(body) == %{"name" => "ada", "nickname" => "Bob"}
    end

    test "a None field is omitted from the JSON object", %{mod: mod} do
      assert {:ok, 200, body, :json} = Handler.dispatch(mod, :get, "/without", [], "")
      assert Jason.decode!(body) == %{"name" => "ada"}
    end
  end

  describe "decode and construction agree" do
    setup do
      # The handler compares the decoded body against a freshly constructed
      # record with Skein `==` — structural equality only holds if the two
      # boundary representations are identical terms.
      mod =
        compile!("""
        module Check {
          capability http.in

          type User {
            name: String
            nickname: Option[String]
          }

          handler http POST "/check_with" (req) -> {
            let user = req.json[User]!
            match user == User { name: "ada", nickname: "Bob" } {
              true -> respond.json(200, "equal")
              false -> respond.json(500, "different")
            }
          }

          handler http POST "/check_without" (req) -> {
            let user = req.json[User]!
            match user == User { name: "ada" } {
              true -> respond.json(200, "equal")
              false -> respond.json(500, "different")
            }
          }
        }
        """)

      {:ok, mod: mod}
    end

    test "a decoded record with a present optional field equals the constructed one",
         %{mod: mod} do
      assert {:ok, 200, body, :json} =
               Handler.dispatch(
                 mod,
                 :post,
                 "/check_with",
                 [],
                 ~s({"name":"ada","nickname":"Bob"})
               )

      assert Jason.decode!(body) == "equal"
    end

    test "a decoded record with an absent optional field equals the constructed one",
         %{mod: mod} do
      assert {:ok, 200, body, :json} =
               Handler.dispatch(mod, :post, "/check_without", [], ~s({"name":"ada"}))

      assert Jason.decode!(body) == "equal"
    end
  end
end
