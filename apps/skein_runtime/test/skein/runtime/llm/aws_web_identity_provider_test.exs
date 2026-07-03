defmodule Skein.Runtime.Llm.AwsWebIdentityProviderTest do
  @moduledoc """
  Tests for the EKS IRSA web-identity credential provider against a
  stub STS server — the inference- and AWS-free CI path for the
  Bedrock credential chain (issue #179).
  """
  use ExUnit.Case, async: false

  # The chain e2e test starts/stops :aws_credentials, which logs
  # lifecycle notices; keep them out of the suite output.
  @moduletag capture_log: true

  alias Skein.Runtime.Llm.AwsWebIdentityProvider
  alias Skein.Runtime.Llm.BedrockBackend
  alias Skein.Runtime.Llm.Response

  # Serves both the STS AssumeRoleWithWebIdentity call (form-encoded
  # body) and Bedrock Converse (JSON body); every request is echoed to
  # the test process for assertions.
  defmodule StubServer do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, raw, conn} = read_body(conn)

      decoded =
        case get_req_header(conn, "content-type") do
          ["application/x-www-form-urlencoded" <> _ | _] -> URI.decode_query(raw)
          _ -> if raw == "", do: %{}, else: Jason.decode!(raw)
        end

      send(opts[:owner], {:stub_request, conn.request_path, decoded, conn.req_headers})
      {status, response} = opts[:respond].(conn.request_path, decoded)

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

  @irsa_env ~w(AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
               AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION)

  defp snapshot_env do
    previous = Enum.map(@irsa_env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    Enum.each(@irsa_env, &System.delete_env/1)
  end

  defp put_irsa_env(role_arn) do
    snapshot_env()

    token_file =
      Path.join(System.tmp_dir!(), "skein-irsa-token-#{System.unique_integer([:positive])}")

    File.write!(token_file, "the-oidc-token\n")
    on_exit(fn -> File.rm(token_file) end)

    System.put_env("AWS_WEB_IDENTITY_TOKEN_FILE", token_file)
    System.put_env("AWS_ROLE_ARN", role_arn)
    token_file
  end

  defp sts_response(expiration) do
    %{
      "AssumeRoleWithWebIdentityResponse" => %{
        "AssumeRoleWithWebIdentityResult" => %{
          "Credentials" => %{
            "AccessKeyId" => "ASIAWEB",
            "SecretAccessKey" => "web-secret",
            "SessionToken" => "web-session-token",
            "Expiration" => expiration
          }
        }
      }
    }
  end

  describe "fetch/1" do
    test "assumes the role with the web identity token" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")
      base_url = start_stub(fn _path, _body -> {200, sts_response(future_epoch(3600))} end)

      assert {:ok, creds, expiration} =
               AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})

      assert creds[:credential_provider] == AwsWebIdentityProvider
      assert creds[:access_key_id] == "ASIAWEB"
      assert creds[:secret_access_key] == "web-secret"
      assert creds[:token] == "web-session-token"
      assert is_integer(expiration)
      assert expiration in 600..3600

      assert_receive {:stub_request, "/", params, _headers}
      assert params["Action"] == "AssumeRoleWithWebIdentity"
      assert params["Version"] == "2011-06-15"
      assert params["RoleArn"] == "arn:aws:iam::123456789012:role/skein-service"
      assert params["RoleSessionName"] == "skein-runtime"
      assert params["WebIdentityToken"] == "the-oidc-token"
    end

    test "AWS_ROLE_SESSION_NAME overrides the session name" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")
      System.put_env("AWS_ROLE_SESSION_NAME", "custom-session")
      base_url = start_stub(fn _path, _body -> {200, sts_response(future_epoch(3600))} end)

      assert {:ok, _, _} = AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})

      assert_receive {:stub_request, _, params, _}
      assert params["RoleSessionName"] == "custom-session"
    end

    test "near-expired credentials clamp the refresh window" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")
      base_url = start_stub(fn _path, _body -> {200, sts_response(future_epoch(60))} end)

      assert {:ok, _, 600} = AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})
    end

    test "an ISO 8601 expiration passes through for the chain to parse" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")
      base_url = start_stub(fn _path, _body -> {200, sts_response("2099-01-01T00:00:00Z")} end)

      assert {:ok, _, "2099-01-01T00:00:00Z"} =
               AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})
    end

    test "missing IRSA env vars fall through as an error" do
      snapshot_env()

      assert {:error, {:env_not_set, "AWS_WEB_IDENTITY_TOKEN_FILE"}} =
               AwsWebIdentityProvider.fetch(%{})
    end

    test "an unreadable token file is an error" do
      snapshot_env()
      System.put_env("AWS_WEB_IDENTITY_TOKEN_FILE", "/nonexistent/token")
      System.put_env("AWS_ROLE_ARN", "arn:aws:iam::123456789012:role/skein-service")

      assert {:error, {:web_identity_token_unreadable, "/nonexistent/token", :enoent}} =
               AwsWebIdentityProvider.fetch(%{})
    end

    test "a non-200 STS response is an error" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")

      base_url =
        start_stub(fn _path, _body ->
          {403, %{"Error" => %{"Code" => "ExpiredTokenException"}}}
        end)

      assert {:error, {:sts_error, 403}} = AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})
    end

    test "an unexpected STS response shape is an error" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")
      base_url = start_stub(fn _path, _body -> {200, %{"unexpected" => true}} end)

      assert {:error, :unexpected_sts_response} =
               AwsWebIdentityProvider.fetch(%{sts_base_url: base_url})
    end
  end

  describe "through the Bedrock credential chain" do
    test "IRSA credentials reach Bedrock with no env-var ceremony" do
      put_irsa_env("arn:aws:iam::123456789012:role/skein-service")

      converse_response = %{
        "output" => %{
          "message" => %{"role" => "assistant", "content" => [%{"text" => "from EKS"}]}
        },
        "stopReason" => "end_turn"
      }

      base_url =
        start_stub(fn
          "/", _body -> {200, sts_response(future_epoch(3600))}
          "/model/" <> _, _body -> {200, converse_response}
        end)

      Application.stop(:aws_credentials)

      Application.put_env(:aws_credentials, :credential_providers, [AwsWebIdentityProvider],
        persistent: true
      )

      Application.put_env(:aws_credentials, :provider_options, %{sts_base_url: base_url},
        persistent: true
      )

      on_exit(fn ->
        Application.stop(:aws_credentials)
        Application.delete_env(:aws_credentials, :credential_providers, persistent: true)
        Application.delete_env(:aws_credentials, :provider_options, persistent: true)
      end)

      assert {:ok, %Response{text: "from EKS"}} =
               BedrockBackend.chat("m", "s", "i", %{base_url: base_url, region: "us-west-2"})

      assert_receive {:stub_request, "/", %{"Action" => "AssumeRoleWithWebIdentity"}, _}
      assert_receive {:stub_request, "/model/m/converse", _, headers}

      headers = Map.new(headers)
      assert headers["authorization"] =~ "Credential=ASIAWEB/"
      assert headers["x-amz-security-token"] == "web-session-token"
    end
  end

  defp future_epoch(seconds_from_now), do: System.system_time(:second) + seconds_from_now
end
