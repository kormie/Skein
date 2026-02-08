defmodule Skein.Runtime.CapabilityTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Capability

  # ------------------------------------------------------------------
  # Host extraction
  # ------------------------------------------------------------------

  describe "extract_host/1" do
    test "extracts host from https URL" do
      assert {:ok, "api.example.com"} = Capability.extract_host("https://api.example.com/path")
    end

    test "extracts host from http URL" do
      assert {:ok, "api.example.com"} = Capability.extract_host("http://api.example.com/path")
    end

    test "extracts host from URL with port" do
      assert {:ok, "api.example.com"} =
               Capability.extract_host("https://api.example.com:8443/path")
    end

    test "returns error for non-URL string" do
      assert {:error, _} = Capability.extract_host("not-a-url")
    end
  end

  # ------------------------------------------------------------------
  # Capability checking
  # ------------------------------------------------------------------

  describe "check_http/2" do
    test "allows URL matching declared host" do
      capabilities = [%{kind: "http.out", params: ["api.example.com"]}]
      assert :ok = Capability.check_http("https://api.example.com/data", capabilities)
    end

    test "allows URL when host matches one of multiple capabilities" do
      capabilities = [
        %{kind: "http.out", params: ["api.one.com"]},
        %{kind: "http.out", params: ["api.two.com"]}
      ]

      assert :ok = Capability.check_http("https://api.two.com/data", capabilities)
    end

    test "blocks URL to undeclared host" do
      capabilities = [%{kind: "http.out", params: ["api.allowed.com"]}]

      assert {:error, reason} =
               Capability.check_http("https://api.blocked.com/data", capabilities)

      assert reason =~ "api.blocked.com"
      assert reason =~ "not declared"
    end

    test "blocks URL when no capabilities are declared" do
      assert {:error, _} = Capability.check_http("https://api.example.com/data", [])
    end

    test "allows any URL when capability has no params (wildcard)" do
      capabilities = [%{kind: "http.out", params: []}]
      assert :ok = Capability.check_http("https://any.host.com/data", capabilities)
    end

    test "ignores non-http capabilities" do
      capabilities = [%{kind: "store.table", params: ["users"]}]
      assert {:error, _} = Capability.check_http("https://api.example.com/data", capabilities)
    end

    test "handles URL with path and query string" do
      capabilities = [%{kind: "http.out", params: ["api.example.com"]}]
      assert :ok = Capability.check_http("https://api.example.com/v2/users?page=1", capabilities)
    end
  end
end
