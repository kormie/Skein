defmodule Skein.Runtime.HandlerTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Handler

  # ------------------------------------------------------------------
  # Route matching
  # ------------------------------------------------------------------

  describe "match_route/3" do
    test "matches exact path" do
      assert {:ok, %{}} = Handler.match_route(["users"], ["users"], %{})
    end

    test "matches root path" do
      assert {:ok, %{}} = Handler.match_route([], [], %{})
    end

    test "matches path with parameter" do
      assert {:ok, %{id: "123"}} =
               Handler.match_route([":id"], ["123"], %{})
    end

    test "matches path with multiple segments and parameter" do
      assert {:ok, %{id: "456"}} =
               Handler.match_route(["users", ":id"], ["users", "456"], %{})
    end

    test "matches path with multiple parameters" do
      assert {:ok, %{user_id: "1", post_id: "2"}} =
               Handler.match_route(
                 ["users", ":user_id", "posts", ":post_id"],
                 ["users", "1", "posts", "2"],
                 %{}
               )
    end

    test "no match when segment differs" do
      assert :no_match = Handler.match_route(["users"], ["posts"], %{})
    end

    test "no match when path is longer" do
      assert :no_match = Handler.match_route(["users"], ["users", "123"], %{})
    end

    test "no match when route is longer" do
      assert :no_match = Handler.match_route(["users", ":id"], ["users"], %{})
    end
  end

  # ------------------------------------------------------------------
  # find_handler/3
  # ------------------------------------------------------------------

  describe "find_handler/3" do
    test "finds matching handler by method and path" do
      handlers = [
        %{method: :get, route: "/users", handler: :__handler_0__},
        %{method: :post, route: "/users", handler: :__handler_1__}
      ]

      assert {:ok, %{handler: :__handler_0__}, %{}} =
               Handler.find_handler(handlers, :get, "/users")
    end

    test "finds handler with path params" do
      handlers = [
        %{method: :get, route: "/users/:id", handler: :__handler_0__}
      ]

      assert {:ok, %{handler: :__handler_0__}, %{id: "123"}} =
               Handler.find_handler(handlers, :get, "/users/123")
    end

    test "returns not_found for unmatched method" do
      handlers = [
        %{method: :get, route: "/users", handler: :__handler_0__}
      ]

      assert :not_found = Handler.find_handler(handlers, :post, "/users")
    end

    test "returns not_found for unmatched path" do
      handlers = [
        %{method: :get, route: "/users", handler: :__handler_0__}
      ]

      assert :not_found = Handler.find_handler(handlers, :get, "/posts")
    end

    test "matches first handler when multiple match" do
      handlers = [
        %{method: :get, route: "/users", handler: :__handler_0__},
        %{method: :get, route: "/users", handler: :__handler_1__}
      ]

      assert {:ok, %{handler: :__handler_0__}, %{}} =
               Handler.find_handler(handlers, :get, "/users")
    end

    test "distinguishes between parameterized and exact routes" do
      handlers = [
        %{method: :get, route: "/users", handler: :list_handler},
        %{method: :get, route: "/users/:id", handler: :get_handler}
      ]

      assert {:ok, %{handler: :list_handler}, %{}} =
               Handler.find_handler(handlers, :get, "/users")

      assert {:ok, %{handler: :get_handler}, %{id: "123"}} =
               Handler.find_handler(handlers, :get, "/users/123")
    end
  end
end
