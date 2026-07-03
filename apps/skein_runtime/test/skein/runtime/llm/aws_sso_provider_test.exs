defmodule Skein.Runtime.Llm.AwsSsoProviderTest do
  @moduledoc """
  Tests for the IAM Identity Center (SSO) credential provider against a
  stub SSO portal — the AWS-free CI path for `aws sso login`-based
  local dev (issue #236).
  """
  use ExUnit.Case, async: false

  # The chain e2e tests start/stop :aws_credentials, which logs
  # lifecycle notices; keep them out of the suite output.
  @moduletag capture_log: true

  alias Skein.Runtime.Llm.AwsSsoProvider
  alias Skein.Runtime.Llm.BedrockBackend
  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Llm.Response

  # Serves the SSO portal's GetRoleCredentials (GET, query params,
  # bearer-token header) and Bedrock Converse (POST, JSON body); every
  # request is echoed to the test process for assertions.
  defmodule StubServer do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      send(
        opts[:owner],
        {:stub_request, conn.request_path, conn.query_params, body, conn.req_headers}
      )

      {status, response} = opts[:respond].(conn.request_path, conn.query_params)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  defp start_stub(respond) do
    {pid, port} =
      Skein.Runtime.TestPorts.start_bandit!(plug: {StubServer, [owner: self(), respond: respond]})

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    "http://127.0.0.1:#{port}"
  end

  @aws_env ~w(AWS_PROFILE AWS_CONFIG_FILE
              AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION)

  defp snapshot_env do
    previous = Enum.map(@aws_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    Enum.each(@aws_env, &System.delete_env/1)
  end

  @modern_config """
  # Identity Center via an sso-session section
  [profile dev]
  sso_session = my-org
  sso_account_id = 123456789012
  sso_role_name = Developer
  region = eu-west-1

  [sso-session my-org]
  sso_start_url = https://my-org.awsapps.com/start
  sso_region = us-east-1
  sso_registration_scopes = sso:account:access
  """

  @legacy_config """
  [profile legacy]
  sso_start_url = https://my-org.awsapps.com/start
  sso_region = us-east-1
  sso_account_id = 123456789012
  sso_role_name = Developer
  """

  # Writes a config file and a token cache, returning provider options
  # pointing at both. `cache_key` is the sso-session name (modern) or
  # the start URL (legacy) — the sha1 the AWS CLI names cache files by.
  defp sso_fixture(config_content, cache_key, cache_overrides \\ %{}) do
    base = Path.join(System.tmp_dir!(), "skein-sso-#{System.unique_integer([:positive])}")
    cache_dir = Path.join(base, "cache")
    File.mkdir_p!(cache_dir)
    on_exit(fn -> File.rm_rf(base) end)

    config_file = Path.join(base, "config")
    File.write!(config_file, config_content)

    token =
      Map.merge(
        %{
          "accessToken" => "the-sso-token",
          "expiresAt" =>
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
          "startUrl" => "https://my-org.awsapps.com/start",
          "region" => "us-east-1"
        },
        cache_overrides
      )

    sha1 = :crypto.hash(:sha, cache_key) |> Base.encode16(case: :lower)
    File.write!(Path.join(cache_dir, sha1 <> ".json"), Jason.encode!(token))

    %{config_file: config_file, sso_cache_dir: cache_dir}
  end

  defp role_credentials_response do
    %{
      "roleCredentials" => %{
        "accessKeyId" => "ASIASSO",
        "secretAccessKey" => "sso-secret",
        "sessionToken" => "sso-session-token",
        "expiration" => System.system_time(:millisecond) + 3_600_000
      }
    }
  end

  describe "fetch/1" do
    test "resolves role credentials for an sso-session profile" do
      snapshot_env()
      options = sso_fixture(@modern_config, "my-org")
      base_url = start_stub(fn _path, _query -> {200, role_credentials_response()} end)
      options = Map.merge(options, %{profile: "dev", sso_portal_base_url: base_url})

      assert {:ok, creds, expiration} = AwsSsoProvider.fetch(options)

      assert creds[:credential_provider] == AwsSsoProvider
      assert creds[:access_key_id] == "ASIASSO"
      assert creds[:secret_access_key] == "sso-secret"
      assert creds[:token] == "sso-session-token"
      assert creds[:region] == "eu-west-1"
      assert is_integer(expiration)
      assert expiration in 600..3600

      assert_receive {:stub_request, "/federation/credentials", query, _body, headers}
      assert query == %{"account_id" => "123456789012", "role_name" => "Developer"}
      assert Map.new(headers)["x-amz-sso_bearer_token"] == "the-sso-token"
    end

    test "resolves a legacy inline-sso profile via the start-URL cache key" do
      snapshot_env()
      options = sso_fixture(@legacy_config, "https://my-org.awsapps.com/start")
      base_url = start_stub(fn _path, _query -> {200, role_credentials_response()} end)
      options = Map.merge(options, %{profile: "legacy", sso_portal_base_url: base_url})

      assert {:ok, creds, _expiration} = AwsSsoProvider.fetch(options)
      assert creds[:access_key_id] == "ASIASSO"
      # No region on the legacy profile fixture.
      refute Map.has_key?(creds, :region)
    end

    test "AWS_PROFILE selects the profile when no option is given" do
      snapshot_env()
      options = sso_fixture(@modern_config, "my-org")
      base_url = start_stub(fn _path, _query -> {200, role_credentials_response()} end)
      System.put_env("AWS_PROFILE", "dev")

      assert {:ok, _creds, _expiration} =
               AwsSsoProvider.fetch(Map.put(options, :sso_portal_base_url, base_url))
    end

    test "an expired token cache falls through without calling the portal" do
      snapshot_env()

      options =
        sso_fixture(@modern_config, "my-org", %{
          "expiresAt" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        })

      assert {:error, {:sso_session_expired, "dev"}} =
               AwsSsoProvider.fetch(Map.put(options, :profile, "dev"))
    end

    test "legacy botocore UTC-suffixed expirations parse" do
      snapshot_env()

      options =
        sso_fixture(@modern_config, "my-org", %{"expiresAt" => "2099-01-01T00:00:00UTC"})

      base_url = start_stub(fn _path, _query -> {200, role_credentials_response()} end)
      options = Map.merge(options, %{profile: "dev", sso_portal_base_url: base_url})

      assert {:ok, _creds, _expiration} = AwsSsoProvider.fetch(options)
    end

    test "a missing token cache means the user never logged in" do
      snapshot_env()
      options = sso_fixture(@modern_config, "wrong-cache-key")

      assert {:error, {:sso_token_missing, "dev"}} =
               AwsSsoProvider.fetch(Map.put(options, :profile, "dev"))
    end

    test "a non-SSO profile falls through as not_sso_profile" do
      snapshot_env()
      options = sso_fixture("[profile plain]\nregion = us-west-2\n", "unused")

      assert {:error, :not_sso_profile} =
               AwsSsoProvider.fetch(Map.put(options, :profile, "plain"))
    end

    test "an incomplete SSO profile names the missing keys" do
      snapshot_env()

      config = """
      [profile dev]
      sso_session = my-org
      sso_role_name = Developer

      [sso-session my-org]
      sso_start_url = https://my-org.awsapps.com/start
      sso_region = us-east-1
      """

      options = sso_fixture(config, "my-org")

      assert {:error, {:incomplete_sso_profile, [:account_id]}} =
               AwsSsoProvider.fetch(Map.put(options, :profile, "dev"))
    end

    test "a rejected token is sso_unauthorized" do
      snapshot_env()
      options = sso_fixture(@modern_config, "my-org")

      base_url =
        start_stub(fn _path, _query -> {401, %{"message" => "Session token not found"}} end)

      assert {:error, {:sso_unauthorized, 401}} =
               AwsSsoProvider.fetch(
                 Map.merge(options, %{profile: "dev", sso_portal_base_url: base_url})
               )
    end

    test "a missing config file falls through" do
      snapshot_env()

      assert {:error, {:config_file_unreadable, :enoent}} =
               AwsSsoProvider.fetch(%{config_file: "/nonexistent/aws/config", profile: "dev"})
    end

    test "tolerates real-world config files with nested blocks and comments" do
      snapshot_env()

      config = """
      # global tooling config
      [default]
      region = us-west-2
      s3 =
        addressing_style = path
        max_concurrent_requests = 20

      ; another comment style
      [profile dev]
      sso_session = my-org
      sso_account_id = 123456789012
      sso_role_name = Developer

      [sso-session my-org]
      sso_start_url = https://my-org.awsapps.com/start
      sso_region = us-east-1
      """

      options = sso_fixture(config, "my-org")
      base_url = start_stub(fn _path, _query -> {200, role_credentials_response()} end)

      assert {:ok, _creds, _expiration} =
               AwsSsoProvider.fetch(
                 Map.merge(options, %{profile: "dev", sso_portal_base_url: base_url})
               )
    end
  end

  describe "sso_login_hint/0" do
    test "names the active SSO profile and the login command" do
      snapshot_env()
      options = sso_fixture(@modern_config, "my-org")
      System.put_env("AWS_PROFILE", "dev")
      put_provider_options(options)

      assert AwsSsoProvider.sso_login_hint() ==
               "Profile 'dev' uses IAM Identity Center — run: aws sso login --profile dev"
    end

    test "is nil for non-SSO setups" do
      snapshot_env()
      options = sso_fixture("[profile plain]\nregion = us-west-2\n", "unused")
      System.put_env("AWS_PROFILE", "plain")
      put_provider_options(options)

      assert AwsSsoProvider.sso_login_hint() == nil
    end
  end

  describe "through the Bedrock credential chain" do
    test "a logged-in SSO profile serves Bedrock, region included, no env-var ceremony" do
      snapshot_env()
      fixture = sso_fixture(@modern_config, "my-org")
      System.put_env("AWS_PROFILE", "dev")

      converse_response = %{
        "output" => %{
          "message" => %{"role" => "assistant", "content" => [%{"text" => "from SSO"}]}
        },
        "stopReason" => "end_turn"
      }

      base_url =
        start_stub(fn
          "/federation/credentials", _query -> {200, role_credentials_response()}
          "/model/" <> _, _query -> {200, converse_response}
        end)

      configure_chain(
        [AwsSsoProvider],
        Map.put(fixture, :sso_portal_base_url, base_url)
      )

      # No region in the backend config and no AWS_REGION: the
      # profile's region must carry through the chain.
      assert {:ok, %Response{text: "from SSO"}} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url})

      assert_receive {:stub_request, "/federation/credentials", _, _, _}
      assert_receive {:stub_request, "/model/m/converse", _, _, headers}

      headers = Map.new(headers)
      assert headers["authorization"] =~ "Credential=ASIASSO/"
      assert headers["authorization"] =~ "/eu-west-1/bedrock/aws4_request"
      assert headers["x-amz-security-token"] == "sso-session-token"
    end

    test "an exhausted chain on an SSO profile says to run aws sso login" do
      snapshot_env()

      fixture =
        sso_fixture(@modern_config, "my-org", %{
          "expiresAt" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        })

      System.put_env("AWS_PROFILE", "dev")
      configure_chain([AwsSsoProvider], fixture)

      assert {:error, %Error{kind: :provider_error, detail: detail}} =
               BedrockBackend.chat("m", "s", "i", %{
                 base_url: "http://unused",
                 region: "us-east-1"
               })

      assert detail.code == "missing_credentials"
      assert detail.message =~ "aws sso login --profile dev"
    end
  end

  defp put_provider_options(options) do
    previous = Application.get_env(:aws_credentials, :provider_options)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:aws_credentials, :provider_options, persistent: true)
      else
        Application.put_env(:aws_credentials, :provider_options, previous, persistent: true)
      end
    end)

    Application.put_env(:aws_credentials, :provider_options, options, persistent: true)
  end

  defp configure_chain(providers, provider_options) do
    Application.stop(:aws_credentials)
    Application.put_env(:aws_credentials, :credential_providers, providers, persistent: true)
    put_provider_options(provider_options)

    on_exit(fn ->
      Application.stop(:aws_credentials)
      Application.delete_env(:aws_credentials, :credential_providers, persistent: true)
    end)
  end
end
