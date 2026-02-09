defmodule Skein.Runtime.HandlerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Runtime.Handler

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp http_status_code do
    StreamData.member_of([200, 201, 204, 301, 400, 404, 500])
  end

  defp response_body_string do
    gen all(value <- StreamData.string(:alphanumeric, min_length: 1, max_length: 200)) do
      value
    end
  end

  defp respond_type do
    StreamData.member_of([:respond_json, :respond_text, :respond_html])
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "all respond types produce {:ok, status, body, content_type} from handler dispatch" do
    check all(
            type <- respond_type(),
            status <- http_status_code(),
            body <- response_body_string()
          ) do
      mod_name = :"Elixir.Skein.User.PropTest#{System.unique_integer([:positive])}"

      handlers = [%{method: :get, route: "/test", handler: :__handler_0__, source: :http}]

      Module.create(
        mod_name,
        quote do
          def __handlers__, do: unquote(Macro.escape(handlers))
          def __handler_0__(_req), do: {unquote(type), unquote(status), unquote(body)}
        end,
        Macro.Env.location(__ENV__)
      )

      result = Handler.dispatch(mod_name, :get, "/test", %{}, "")

      case type do
        :respond_json ->
          assert {:ok, ^status, json_body, :json} = result
          assert Jason.decode!(json_body) == body

        :respond_text ->
          assert {:ok, ^status, ^body, :text} = result

        :respond_html ->
          assert {:ok, ^status, ^body, :html} = result
      end

      :code.purge(mod_name)
      :code.delete(mod_name)
    end
  end

  property "arbitrary status codes and body strings produce valid responses for respond.text" do
    check all(
            status <- StreamData.integer(100..599),
            body <- response_body_string()
          ) do
      mod_name = :"Elixir.Skein.User.PropTextStatus#{System.unique_integer([:positive])}"

      handlers = [%{method: :get, route: "/test", handler: :__handler_0__, source: :http}]

      Module.create(
        mod_name,
        quote do
          def __handlers__, do: unquote(Macro.escape(handlers))
          def __handler_0__(_req), do: {:respond_text, unquote(status), unquote(body)}
        end,
        Macro.Env.location(__ENV__)
      )

      assert {:ok, ^status, ^body, :text} = Handler.dispatch(mod_name, :get, "/test", %{}, "")

      :code.purge(mod_name)
      :code.delete(mod_name)
    end
  end

  property "arbitrary status codes and body strings produce valid responses for respond.html" do
    check all(
            status <- StreamData.integer(100..599),
            body <- response_body_string()
          ) do
      mod_name = :"Elixir.Skein.User.PropHtmlStatus#{System.unique_integer([:positive])}"

      handlers = [%{method: :get, route: "/test", handler: :__handler_0__, source: :http}]

      Module.create(
        mod_name,
        quote do
          def __handlers__, do: unquote(Macro.escape(handlers))
          def __handler_0__(_req), do: {:respond_html, unquote(status), unquote(body)}
        end,
        Macro.Env.location(__ENV__)
      )

      assert {:ok, ^status, ^body, :html} = Handler.dispatch(mod_name, :get, "/test", %{}, "")

      :code.purge(mod_name)
      :code.delete(mod_name)
    end
  end
end
