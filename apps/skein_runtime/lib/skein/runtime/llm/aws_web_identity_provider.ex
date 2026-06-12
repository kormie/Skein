defmodule Skein.Runtime.Llm.AwsWebIdentityProvider do
  @moduledoc """
  `:aws_credentials` provider for STS AssumeRoleWithWebIdentity — the
  EKS IRSA (IAM Roles for Service Accounts) credential source.

  EKS injects `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` into
  pods whose service account binds an IAM role. The `:aws_credentials`
  library's built-in chain does not cover this source, so the Bedrock
  backend inserts this provider into the chain it configures (see
  `Skein.Runtime.Llm.BedrockBackend`).

  The STS call is deliberately unsigned — the web identity token itself
  authenticates the request — so this provider needs no credentials to
  fetch credentials. `AWS_ROLE_SESSION_NAME` overrides the session
  name; provider option `:sts_base_url` (via the `:aws_credentials`
  application's `provider_options`) overrides the STS endpoint for VPC
  endpoints or tests, otherwise the region's endpoint (`AWS_REGION` /
  `AWS_DEFAULT_REGION`) or the global one is used.
  """

  @behaviour :aws_credentials_provider

  @sts_version "2011-06-15"
  @connect_timeout 3_000
  @receive_timeout 10_000
  # Never schedule a refresh sooner than 10 minutes: aws_credentials
  # subtracts a 5-minute alert window from the expiration we return,
  # and erlang:send_after rejects non-positive delays.
  @min_expiration_seconds 600

  @doc """
  Resolves credentials via AssumeRoleWithWebIdentity when the IRSA
  environment variables are present.

  Returns `{:ok, credentials, seconds_until_expiry}` or `{:error, reason}`
  (an error makes the `:aws_credentials` chain fall through to the next
  provider).
  """
  @impl true
  @spec fetch(map()) :: {:ok, map(), pos_integer() | binary()} | {:error, any()}
  def fetch(options) do
    with {:ok, token_file} <- require_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
         {:ok, role_arn} <- require_env("AWS_ROLE_ARN"),
         {:ok, token} <- read_token(token_file) do
      assume_role(role_arn, token, options)
    end
  end

  defp require_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:env_not_set, name}}
    end
  end

  defp read_token(token_file) do
    case File.read(token_file) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, reason} -> {:error, {:web_identity_token_unreadable, token_file, reason}}
    end
  end

  defp assume_role(role_arn, token, options) do
    params = %{
      "Action" => "AssumeRoleWithWebIdentity",
      "Version" => @sts_version,
      "RoleArn" => role_arn,
      "RoleSessionName" => session_name(),
      "WebIdentityToken" => token
    }

    with {:ok, _} <- Application.ensure_all_started(:req) do
      case Req.post(sts_url(options),
             form: params,
             headers: [{"accept", "application/json"}],
             connect_options: [timeout: @connect_timeout],
             receive_timeout: @receive_timeout,
             retry: false
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          parse_credentials(body)

        {:ok, %Req.Response{status: status}} ->
          {:error, {:sts_error, status}}

        {:error, exception} ->
          # Exception messages never embed the request body (where the
          # token travels), so they are safe to surface.
          {:error, {:sts_transport_error, Exception.message(exception)}}
      end
    end
  end

  defp parse_credentials(%{
         "AssumeRoleWithWebIdentityResponse" => %{
           "AssumeRoleWithWebIdentityResult" => %{
             "Credentials" => %{
               "AccessKeyId" => access_key_id,
               "SecretAccessKey" => secret_access_key,
               "SessionToken" => session_token,
               "Expiration" => expiration
             }
           }
         }
       }) do
    credentials =
      :aws_credentials.make_map(__MODULE__, access_key_id, secret_access_key, session_token)

    {:ok, credentials, expiration_for_chain(expiration)}
  end

  defp parse_credentials(_other), do: {:error, :unexpected_sts_response}

  # With `accept: application/json` STS renders Expiration as epoch
  # seconds; aws_credentials expects an integer to mean seconds *until*
  # expiry (it treats binaries as absolute ISO 8601 timestamps).
  defp expiration_for_chain(epoch) when is_number(epoch) do
    max(round(epoch) - System.system_time(:second), @min_expiration_seconds)
  end

  defp expiration_for_chain(iso8601) when is_binary(iso8601), do: iso8601

  defp session_name do
    System.get_env("AWS_ROLE_SESSION_NAME") || "skein-runtime"
  end

  defp sts_url(options) when is_map(options) do
    case options[:sts_base_url] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> regional_sts_url()
    end
  end

  defp sts_url(_options), do: regional_sts_url()

  defp regional_sts_url do
    case System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") do
      region when is_binary(region) and region != "" -> "https://sts.#{region}.amazonaws.com"
      _ -> "https://sts.amazonaws.com"
    end
  end
end
