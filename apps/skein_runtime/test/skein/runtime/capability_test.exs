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

  # ------------------------------------------------------------------
  # Scoped capability labels (process.spawn / timer / event.log)
  # ------------------------------------------------------------------

  describe "check_scoped/3" do
    test "blocks when no capability of the kind is declared" do
      assert {:error, reason} = Capability.check_scoped("event.log", "audit", [])
      assert reason =~ "event.log"
      assert reason =~ "not declared"
    end

    test "ignores capabilities of other kinds" do
      capabilities = [%{kind: "timer", params: ["audit"]}]
      assert {:error, _} = Capability.check_scoped("event.log", "audit", capabilities)
    end

    test "permits a label matching the declared label" do
      capabilities = [%{kind: "process.spawn", params: ["workers"]}]
      assert :ok = Capability.check_scoped("process.spawn", "workers", capabilities)
    end

    test "blocks a label outside the declared label" do
      capabilities = [%{kind: "process.spawn", params: ["workers"]}]

      assert {:error, reason} = Capability.check_scoped("process.spawn", "reports", capabilities)
      assert reason =~ "reports"
      assert reason =~ "workers"
    end

    test "permits any label when the declaration is parameterless (unscoped)" do
      capabilities = [%{kind: "timer", params: []}]
      assert :ok = Capability.check_scoped("timer", "maintenance", capabilities)
      assert :ok = Capability.check_scoped("timer", nil, capabilities)
    end

    test "blocks a label-less call when the declaration is scoped" do
      capabilities = [%{kind: "timer", params: ["maintenance"]}]

      assert {:error, reason} = Capability.check_scoped("timer", nil, capabilities)
      assert reason =~ "maintenance"
    end

    test "permits when the label matches any declared param" do
      capabilities = [%{kind: "event.log", params: ["audit", "metrics"]}]
      assert :ok = Capability.check_scoped("event.log", "metrics", capabilities)
    end

    test "permits when the label matches a second capability of the kind" do
      capabilities = [
        %{kind: "event.log", params: ["audit"]},
        %{kind: "event.log", params: ["metrics"]}
      ]

      assert :ok = Capability.check_scoped("event.log", "metrics", capabilities)
    end
  end
end
