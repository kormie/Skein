defmodule Skein.Runtime.Llm.AwsSsoProvider do
  @moduledoc """
  `:aws_credentials` provider for AWS IAM Identity Center (SSO)
  profiles — the `aws sso login` local-dev credential source.

  Resolves the active profile (`AWS_PROFILE`, else `default`) from the
  shared config file (`AWS_CONFIG_FILE`, else `~/.aws/config`),
  supporting both the modern `sso_session = <name>` form and the legacy
  inline `sso_start_url` form. The access token comes from the cache
  `aws sso login` writes under `~/.aws/sso/cache/<sha1>.json` (sha1 of
  the session name, or of the start URL for legacy profiles); role
  credentials then come from the SSO portal's `GetRoleCredentials`
  (`GET /federation/credentials`, authenticated by the bearer token —
  no signing involved). A `region` set on the profile rides along so
  the Bedrock backend's region fallback covers SSO profiles too.

  Token refresh is not attempted: an expired or missing SSO session
  falls through the chain, and `sso_login_hint/0` lets the terminal
  missing-credentials error tell the user to run
  `aws sso login --profile <name>` instead of failing confusingly.

  Provider options (via the `:aws_credentials` application's
  `provider_options`): `:profile`, `:config_file`, `:sso_cache_dir`,
  and `:sso_portal_base_url` override the defaults for tests.
  """

  @behaviour :aws_credentials_provider

  @connect_timeout 3_000
  @receive_timeout 10_000
  # Never schedule a chain refresh sooner than 10 minutes:
  # aws_credentials subtracts a 5-minute alert window and
  # erlang:send_after rejects non-positive delays.
  @min_expiration_seconds 600

  @doc """
  Resolves role credentials for the active SSO profile.

  Returns `{:ok, credentials, seconds_until_expiry}` or
  `{:error, reason}` (an error makes the `:aws_credentials` chain fall
  through to the next provider).
  """
  @impl true
  @spec fetch(map()) :: {:ok, map(), pos_integer()} | {:error, any()}
  def fetch(options) when is_map(options) do
    profile_name = active_profile(options)

    with {:ok, profile, sso} <- sso_settings(profile_name, options),
         {:ok, token} <- cached_access_token(sso, profile_name, options) do
      get_role_credentials(profile, sso, token, options)
    end
  end

  def fetch(_options), do: fetch(%{})

  @doc """
  A fix hint for the terminal missing-credentials error: when the
  active profile is SSO-configured (so the chain *should* have served
  it, but didn't — token missing, expired, or rejected), tells the
  user to log in. `nil` for non-SSO setups.
  """
  @spec sso_login_hint() :: String.t() | nil
  def sso_login_hint do
    options = Application.get_env(:aws_credentials, :provider_options, %{})
    options = if is_map(options), do: options, else: %{}
    profile_name = active_profile(options)

    case sso_settings(profile_name, options) do
      {:ok, _profile, _sso} ->
        "Profile '#{profile_name}' uses IAM Identity Center — run: " <>
          "aws sso login --profile #{profile_name}"

      _ ->
        nil
    end
  rescue
    # A diagnostic for an error message must never replace it with a crash.
    _ -> nil
  end

  # -- Profile + SSO configuration --------------------------------------------

  defp active_profile(options) do
    case options[:profile] || System.get_env("AWS_PROFILE") do
      name when is_binary(name) and name != "" -> name
      _ -> "default"
    end
  end

  defp sso_settings(profile_name, options) do
    with {:ok, config} <- read_config(options),
         {:ok, profile} <- profile_section(config, profile_name) do
      cond do
        is_binary(profile["sso_session"]) ->
          session_name = profile["sso_session"]

          with {:ok, session} <- session_section(config, session_name) do
            require_sso_keys(profile, %{
              start_url: session["sso_start_url"],
              sso_region: session["sso_region"],
              account_id: profile["sso_account_id"],
              role_name: profile["sso_role_name"],
              cache_key: session_name
            })
          end

        is_binary(profile["sso_start_url"]) ->
          require_sso_keys(profile, %{
            start_url: profile["sso_start_url"],
            sso_region: profile["sso_region"],
            account_id: profile["sso_account_id"],
            role_name: profile["sso_role_name"],
            cache_key: profile["sso_start_url"]
          })

        true ->
          {:error, :not_sso_profile}
      end
    end
  end

  defp require_sso_keys(profile, sso) do
    missing = for {key, value} <- sso, !is_binary(value) or value == "", do: key

    if missing == [] do
      {:ok, profile, sso}
    else
      {:error, {:incomplete_sso_profile, missing}}
    end
  end

  defp read_config(options) do
    case File.read(config_file(options)) do
      {:ok, content} -> {:ok, parse_ini(content)}
      {:error, reason} -> {:error, {:config_file_unreadable, reason}}
    end
  end

  defp config_file(options) do
    options[:config_file] || presence(System.get_env("AWS_CONFIG_FILE")) ||
      Path.join([System.user_home() || ".", ".aws", "config"])
  end

  defp profile_section(config, "default") do
    case config["default"] || config["profile default"] do
      nil -> {:error, {:no_such_profile, "default"}}
      profile -> {:ok, profile}
    end
  end

  defp profile_section(config, name) do
    case config["profile #{name}"] do
      nil -> {:error, {:no_such_profile, name}}
      profile -> {:ok, profile}
    end
  end

  defp session_section(config, name) do
    case config["sso-session #{name}"] do
      nil -> {:error, {:no_such_sso_session, name}}
      session -> {:ok, session}
    end
  end

  # Tolerant INI subset for ~/.aws/config: `[section]` headers,
  # top-level `key = value`, `#`/`;` comments. Indented sub-property
  # blocks (`s3 = ...`) and unparseable lines are skipped, never fatal.
  defp parse_ini(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({nil, %{}}, &parse_ini_line/2)
    |> elem(1)
  end

  defp parse_ini_line(line, {section, acc}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, ["#", ";"]) ->
        {section, acc}

      String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") ->
        name = trimmed |> String.slice(1..-2//1) |> String.trim()
        {name, Map.put_new(acc, name, %{})}

      # Indented lines belong to nested sub-property blocks — not ours.
      String.starts_with?(line, [" ", "\t"]) ->
        {section, acc}

      section != nil ->
        case String.split(trimmed, "=", parts: 2) do
          [key, value] -> {section, put_in(acc, [section, String.trim(key)], String.trim(value))}
          _ -> {section, acc}
        end

      true ->
        {section, acc}
    end
  end

  # -- Token cache -------------------------------------------------------------

  defp cached_access_token(sso, profile_name, options) do
    cache_file = Path.join(cache_dir(options), sha1_hex(sso.cache_key) <> ".json")

    with {:ok, raw} <- read_cache(cache_file, profile_name),
         {:ok, %{"accessToken" => token, "expiresAt" => expires_at}} <-
           decode_cache(raw, profile_name) do
      if expired?(expires_at) do
        {:error, {:sso_session_expired, profile_name}}
      else
        {:ok, token}
      end
    end
  end

  defp read_cache(cache_file, profile_name) do
    case File.read(cache_file) do
      {:ok, raw} -> {:ok, raw}
      {:error, _} -> {:error, {:sso_token_missing, profile_name}}
    end
  end

  defp decode_cache(raw, profile_name) do
    case Jason.decode(raw) do
      {:ok, %{"accessToken" => _, "expiresAt" => _} = decoded} -> {:ok, decoded}
      _ -> {:error, {:sso_cache_invalid, profile_name}}
    end
  end

  defp expired?(expires_at) when is_binary(expires_at) do
    # Legacy botocore caches write "...UTC" instead of "...Z".
    normalized = String.replace_suffix(expires_at, "UTC", "Z")

    case DateTime.from_iso8601(normalized) do
      {:ok, expiry, _offset} -> DateTime.compare(expiry, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp expired?(_), do: true

  defp cache_dir(options) do
    options[:sso_cache_dir] ||
      Path.join([System.user_home() || ".", ".aws", "sso", "cache"])
  end

  defp sha1_hex(value) do
    :crypto.hash(:sha, value) |> Base.encode16(case: :lower)
  end

  # -- GetRoleCredentials -------------------------------------------------------

  defp get_role_credentials(profile, sso, token, options) do
    query = URI.encode_query(%{"account_id" => sso.account_id, "role_name" => sso.role_name})
    url = portal_base_url(options, sso.sso_region) <> "/federation/credentials?" <> query

    with {:ok, _} <- Application.ensure_all_started(:req) do
      case Req.get(url,
             headers: [{"x-amz-sso_bearer_token", token}],
             connect_options: [timeout: @connect_timeout],
             receive_timeout: @receive_timeout,
             retry: false
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          parse_role_credentials(body, profile)

        {:ok, %Req.Response{status: status}} when status in [401, 403] ->
          {:error, {:sso_unauthorized, status}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:sso_portal_error, status}}

        {:error, exception} ->
          # Exception messages never embed headers (where the bearer
          # token travels), so they are safe to surface.
          {:error, {:sso_transport_error, Exception.message(exception)}}
      end
    end
  end

  defp parse_role_credentials(
         %{
           "roleCredentials" => %{
             "accessKeyId" => access_key_id,
             "secretAccessKey" => secret_access_key,
             "sessionToken" => session_token,
             "expiration" => expiration_ms
           }
         },
         profile
       )
       when is_number(expiration_ms) do
    credentials =
      case presence(profile["region"]) do
        nil ->
          :aws_credentials.make_map(__MODULE__, access_key_id, secret_access_key, session_token)

        region ->
          :aws_credentials.make_map(
            __MODULE__,
            access_key_id,
            secret_access_key,
            session_token,
            region
          )
      end

    relative = div(round(expiration_ms), 1000) - System.system_time(:second)
    {:ok, credentials, max(relative, @min_expiration_seconds)}
  end

  defp parse_role_credentials(_body, _profile), do: {:error, :unexpected_sso_response}

  defp portal_base_url(options, sso_region) do
    case options[:sso_portal_base_url] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> "https://portal.sso.#{sso_region}.amazonaws.com"
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil
end
