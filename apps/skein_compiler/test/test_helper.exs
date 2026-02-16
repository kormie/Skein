# Load skein_runtime beam files for integration tests that need runtime modules.
# We can't add it as a mix dep (circular: runtime depends on compiler).
umbrella_build = Path.expand("../../../_build/#{Mix.env()}/lib", __DIR__)

if File.dir?(umbrella_build) do
  umbrella_build
  |> File.ls!()
  |> Enum.each(fn lib ->
    ebin = Path.join([umbrella_build, lib, "ebin"])
    if File.dir?(ebin), do: Code.prepend_path(String.to_charlist(ebin))
  end)

  # Ensure key runtime applications are loaded (not started) so their
  # config is available for integration tests
  # Add OTP application ebin paths needed by runtime integration tests
  for otp_app <- [:crypto, :asn1, :public_key, :ssl, :inets] do
    case :code.lib_dir(otp_app, :ebin) do
      {:error, _} ->
        # Try to find it from Erlang's root
        otp_root = :code.root_dir()
        lib_dir = Path.join([to_string(otp_root), "lib"])
        if File.dir?(lib_dir) do
          lib_dir
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, to_string(otp_app)))
          |> Enum.each(fn dir ->
            ebin = Path.join([lib_dir, dir, "ebin"])
            if File.dir?(ebin), do: :code.add_pathz(String.to_charlist(ebin))
          end)
        end
      path ->
        :code.add_pathz(path)
    end
  end

  for app <- [:crypto, :asn1, :public_key, :ssl, :inets, :ecto, :ecto_sql, :telemetry, :db_connection, :decimal] do
    Application.ensure_all_started(app)
  end

  for app <- [:plug, :bandit, :thousand_island, :telemetry, :mime, :hpax, :websock, :plug_crypto] do
    Application.load(app)
  end
end

ExUnit.start()
