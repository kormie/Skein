defmodule Skein.Runtime.Capability do
  @moduledoc """
  Runtime capability enforcement for Skein.

  Provides the second layer of defense beyond compile-time capability checking.
  Validates that effect calls target only hosts declared in the module's
  capability list.
  """

  @doc """
  Extracts the host from a URL string.

  Returns `{:ok, host}` or `{:error, reason}`.
  """
  @spec extract_host(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        {:ok, host}

      _ ->
        {:error, "Cannot extract host from URL: #{url}"}
    end
  end

  @doc """
  Checks whether an HTTP request to the given URL is allowed by the
  declared capabilities.

  Capabilities are maps with `:kind` and `:params` keys.
  An `http.out` capability with empty params acts as a wildcard (allows any host).
  An `http.out` capability with params restricts to those specific hosts.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_http(String.t(), [map()]) :: :ok | {:error, String.t()}
  def check_http(url, capabilities) when is_binary(url) and is_list(capabilities) do
    http_caps =
      Enum.filter(capabilities, fn cap ->
        cap.kind == "http.out"
      end)

    case http_caps do
      [] ->
        {:error, "HTTP capability 'http.out' not declared. Request to #{url} blocked."}

      caps ->
        # Check if any capability allows this URL
        has_wildcard = Enum.any?(caps, fn cap -> cap.params == [] end)

        if has_wildcard do
          :ok
        else
          case extract_host(url) do
            {:ok, host} ->
              allowed_hosts =
                caps
                |> Enum.flat_map(fn cap -> cap.params end)

              if host in allowed_hosts do
                :ok
              else
                {:error,
                 "Host '#{host}' not declared in http.out capabilities. " <>
                   "Allowed hosts: #{Enum.join(allowed_hosts, ", ")}"}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end
end
