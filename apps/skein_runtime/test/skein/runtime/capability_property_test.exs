defmodule Skein.Runtime.CapabilityPropertyTest do
  @moduledoc """
  Property-based tests for runtime capability enforcement.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Runtime.Capability

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp host_gen do
    gen all(
          subdomain <-
            StreamData.string(Enum.to_list(?a..?z), min_length: 3, max_length: 8),
          domain <-
            StreamData.string(Enum.to_list(?a..?z), min_length: 3, max_length: 6),
          tld <- StreamData.member_of(~w(com org net io))
        ) do
      "#{subdomain}.#{domain}.#{tld}"
    end
  end

  defp path_gen do
    gen all(
          segments <-
            StreamData.list_of(
              StreamData.string(Enum.to_list(?a..?z), min_length: 1, max_length: 8),
              min_length: 0,
              max_length: 3
            )
        ) do
      "/" <> Enum.join(segments, "/")
    end
  end

  defp url_gen do
    gen all(
          scheme <- StreamData.member_of(["https", "http"]),
          host <- host_gen(),
          path <- path_gen()
        ) do
      "#{scheme}://#{host}#{path}"
    end
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "URL with matching host capability always passes" do
    check all(
            host <- host_gen(),
            path <- path_gen(),
            scheme <- StreamData.member_of(["https", "http"])
          ) do
      url = "#{scheme}://#{host}#{path}"
      capabilities = [%{kind: "http.out", params: [host]}]
      assert :ok = Capability.check_http(url, capabilities)
    end
  end

  property "URL with non-matching host capability always fails" do
    check all(
            host1 <- host_gen(),
            host2 <- host_gen(),
            path <- path_gen(),
            host1 != host2
          ) do
      url = "https://#{host1}#{path}"
      capabilities = [%{kind: "http.out", params: [host2]}]
      assert {:error, _} = Capability.check_http(url, capabilities)
    end
  end

  property "wildcard capability (no params) allows any URL" do
    check all(url <- url_gen()) do
      capabilities = [%{kind: "http.out", params: []}]
      assert :ok = Capability.check_http(url, capabilities)
    end
  end

  property "empty capabilities list blocks any URL" do
    check all(url <- url_gen()) do
      assert {:error, _} = Capability.check_http(url, [])
    end
  end

  property "extract_host returns the host from any valid URL" do
    check all(
            host <- host_gen(),
            path <- path_gen(),
            scheme <- StreamData.member_of(["https", "http"])
          ) do
      url = "#{scheme}://#{host}#{path}"
      assert {:ok, ^host} = Capability.extract_host(url)
    end
  end
end
