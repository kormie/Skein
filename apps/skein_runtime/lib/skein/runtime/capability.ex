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
  Checks a call against a scoped capability label (spec §3.2).

  For `process.spawn`, `timer`, and `event.log` the capability parameter
  names a scope label (pool/group/stream) that the compiler threads into
  every generated runtime call. Rules:

    * no capability of `kind` declared — blocked
    * any declaration of `kind` with empty params — unscoped, any label
      (including `nil`) is permitted
    * otherwise the call's label must exactly match one of the declared
      params; `nil` (a label-less call) is blocked

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_scoped(String.t(), String.t() | nil, [map()]) :: :ok | {:error, String.t()}
  def check_scoped(kind, label, capabilities)
      when is_binary(kind) and (is_binary(label) or is_nil(label)) and is_list(capabilities) do
    scoped_caps = Enum.filter(capabilities, fn cap -> cap.kind == kind end)

    cond do
      scoped_caps == [] ->
        {:error, "Capability '#{kind}' not declared. Call blocked."}

      Enum.any?(scoped_caps, fn cap -> cap.params == [] end) ->
        :ok

      true ->
        declared_labels = Enum.flat_map(scoped_caps, fn cap -> cap.params end)

        cond do
          is_nil(label) ->
            {:error,
             "Call carries no scope label but '#{kind}' is declared with " <>
               "label(s): #{Enum.join(declared_labels, ", ")}. Call blocked."}

          label in declared_labels ->
            :ok

          true ->
            {:error,
             "'#{label}' not declared in #{kind} capabilities. " <>
               "Declared: #{Enum.join(declared_labels, ", ")}"}
        end
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
