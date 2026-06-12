defmodule Skein.CLI.RenderTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Render

  describe "trace_plain/1" do
    test "renders the empty trace listing" do
      assert Render.trace_plain(%{spans: [], count: 0}) == "Traces (0):"
    end

    test "renders effect spans with method, url, status, and duration" do
      spans = [
        %{
          kind: :http,
          method: :get,
          url: "/api/users",
          status: 200,
          outcome: :ok,
          duration_us: 2500
        },
        %{kind: :llm, method: :chat, url: "anthropic", outcome: :ok, duration_us: 3200}
      ]

      assert Render.trace_plain(%{spans: spans, count: 2}) ==
               """
               Traces (2):
                 [http] get /api/users -> 200 (2.5ms)
                 [llm] chat anthropic (3.2ms)\
               """
    end

    test "renders error outcomes with the error message when present" do
      spans = [
        %{
          kind: :http,
          method: :get,
          url: "/down",
          outcome: :error,
          duration_us: 1000,
          error: "timeout"
        },
        %{kind: :tool, method: :call, url: "lookup_account", outcome: :error, duration_us: 500}
      ]

      assert Render.trace_plain(%{spans: spans, count: 2}) ==
               """
               Traces (2):
                 [http] get /down (1.0ms) error: timeout
                 [tool] call lookup_account (0.5ms) error\
               """
    end

    test "renders annotation spans as key=value" do
      spans = [%{kind: :annotation, key: "deploy", value: "v2"}]

      assert Render.trace_plain(%{spans: spans, count: 1}) ==
               """
               Traces (1):
                 [annotation] deploy=v2\
               """
    end

    test "renders user events with agent and phase context" do
      spans = [
        %{
          kind: :user_event,
          event: "refund_issued",
          data: %{amount: 100},
          agent: "RefundAgent",
          instance_id: "abc",
          phase: :executing
        }
      ]

      assert Render.trace_plain(%{spans: spans, count: 1}) ==
               """
               Traces (1):
                 [user_event] refund_issued agent=RefundAgent phase=executing\
               """
    end

    test "renders state changes as operation namespace/key" do
      spans = [
        %{kind: :state_change, namespace: "orders", operation: :put, key: "order_42", value: %{}}
      ]

      assert Render.trace_plain(%{spans: spans, count: 1}) ==
               """
               Traces (1):
                 [state_change] put orders/order_42\
               """
    end

    test "never raises on spans with missing fields" do
      spans = [
        %{kind: :http},
        %{},
        %{kind: :user_event},
        %{kind: :annotation},
        %{kind: :state_change}
      ]

      output = Render.trace_plain(%{spans: spans, count: 5})

      assert output ==
               """
               Traces (5):
                 [http]
                 [span]
                 [user_event]
                 [annotation]
                 [state_change]\
               """
    end

    test "output is plain ASCII" do
      spans = [
        %{
          kind: :http,
          method: :get,
          url: "/x",
          status: 204,
          outcome: :error,
          duration_us: 123,
          error: "boom"
        },
        %{kind: :annotation, key: "k", value: "v"}
      ]

      output = Render.trace_plain(%{spans: spans, count: 2})
      assert output == for(<<c <- output>>, c < 128, into: "", do: <<c>>)
    end
  end
end
