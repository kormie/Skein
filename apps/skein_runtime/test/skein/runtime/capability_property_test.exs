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

  # ------------------------------------------------------------------
  # Scoped capability labels (check_scoped/3)
  # ------------------------------------------------------------------

  @scoped_kinds ["process.spawn", "timer", "event.log"]

  defp label_gen do
    StreamData.string(Enum.to_list(?a..?z), min_length: 1, max_length: 12)
  end

  defp scoped_capability_gen do
    gen all(
          kind <- StreamData.member_of(@scoped_kinds),
          params <- StreamData.list_of(label_gen(), min_length: 0, max_length: 3)
        ) do
      %{kind: kind, params: params}
    end
  end

  property "a label matching the declared label always permits" do
    check all(kind <- StreamData.member_of(@scoped_kinds), label <- label_gen()) do
      capabilities = [%{kind: kind, params: [label]}]
      assert :ok = Capability.check_scoped(kind, label, capabilities)
    end
  end

  property "a label outside the declared label always denies" do
    check all(
            kind <- StreamData.member_of(@scoped_kinds),
            declared <- label_gen(),
            called <- label_gen(),
            declared != called
          ) do
      capabilities = [%{kind: kind, params: [declared]}]
      assert {:error, _} = Capability.check_scoped(kind, called, capabilities)
    end
  end

  property "an unscoped declaration permits any label" do
    check all(kind <- StreamData.member_of(@scoped_kinds), label <- label_gen()) do
      capabilities = [%{kind: kind, params: []}]
      assert :ok = Capability.check_scoped(kind, label, capabilities)
    end
  end

  property "randomized capability sets permit or deny based on exact label match" do
    check all(
            capabilities <- StreamData.list_of(scoped_capability_gen(), max_length: 5),
            kind <- StreamData.member_of(@scoped_kinds),
            label <- label_gen()
          ) do
      matching = Enum.filter(capabilities, &(&1.kind == kind))

      permitted? =
        matching != [] and
          Enum.any?(matching, fn cap -> cap.params == [] or label in cap.params end)

      case Capability.check_scoped(kind, label, capabilities) do
        :ok -> assert permitted?
        {:error, _} -> refute permitted?
      end
    end
  end
end
