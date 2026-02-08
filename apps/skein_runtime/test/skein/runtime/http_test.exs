defmodule Skein.Runtime.HttpTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Http
  alias Skein.Runtime.Trace

  setup do
    Trace.clear()
    :ok
  end

  # ------------------------------------------------------------------
  # Capability enforcement
  # ------------------------------------------------------------------

  describe "capability enforcement" do
    test "get/2 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.get("https://api.blocked.com/data", capabilities)
      assert reason =~ "not declared"
    end

    test "post/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.post("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "put/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.put("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "patch/3 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.patch("https://api.blocked.com/data", "body", capabilities)
      assert reason =~ "not declared"
    end

    test "delete/2 blocks requests to undeclared hosts" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      assert {:error, reason} = Http.delete("https://api.blocked.com/data", capabilities)
      assert reason =~ "not declared"
    end

    test "get/2 with no capabilities blocks all requests" do
      assert {:error, _} = Http.get("https://api.example.com/data", [])
    end

    test "get/2 with wildcard capability allows any host" do
      # Wildcard = http.out with no params
      capabilities = [%{kind: "http.out", params: []}]
      # This will likely fail to connect but should not be blocked by capability check
      result = Http.get("https://api.example.com/data", capabilities)
      # The result will be either {:ok, _} or {:error, _} from the HTTP call,
      # but NOT a capability error
      case result do
        {:error, reason} -> refute reason =~ "not declared"
        {:ok, _} -> :ok
      end
    end
  end

  # ------------------------------------------------------------------
  # Trace recording
  # ------------------------------------------------------------------

  describe "trace recording" do
    test "blocked request records a trace span" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :http
      assert span.method == :get
      assert span.outcome == :error
    end

    test "trace span includes URL" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      [span] = Trace.recent_spans(1)
      assert span.url == "https://api.blocked.com/data"
    end

    test "trace span includes timing" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]
      Http.get("https://api.blocked.com/data", capabilities)

      [span] = Trace.recent_spans(1)
      assert is_integer(span.duration_us)
      assert span.duration_us >= 0
    end
  end
end
