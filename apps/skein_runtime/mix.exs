defmodule SkeinRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {SkeinRuntime.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4", override: true},
      {:bandit, git: "https://github.com/mtrudel/bandit.git", tag: "1.6.7"},
      {:plug, git: "https://github.com/elixir-plug/plug.git", tag: "v1.16.1", override: true},
      {:plug_crypto,
       git: "https://github.com/elixir-plug/plug_crypto.git", tag: "v2.1.1", override: true},
      {:thousand_island,
       git: "https://github.com/mtrudel/thousand_island.git", tag: "1.3.9", override: true},
      {:hpax, git: "https://github.com/elixir-mint/hpax.git", tag: "v1.0.2", override: true},
      {:websock,
       git: "https://github.com/phoenixframework/websock.git", tag: "0.5.3", override: true},
      {:telemetry,
       git: "https://github.com/beam-telemetry/telemetry.git", tag: "v1.3.0", override: true},
      {:mime, git: "https://github.com/elixir-plug/mime.git", tag: "v2.0.6", override: true},
      # Ecto + SQLite for storage backend
      {:ecto, git: "https://github.com/elixir-ecto/ecto.git", tag: "v3.12.5", override: true},
      {:ecto_sql,
       git: "https://github.com/elixir-ecto/ecto_sql.git", tag: "v3.12.1", override: true},
      {:ecto_sqlite3, git: "https://github.com/elixir-sqlite/ecto_sqlite3.git", tag: "v0.17.5"},
      {:exqlite,
       git: "https://github.com/elixir-sqlite/exqlite.git", tag: "v0.24.2", override: true},
      {:decimal, git: "https://github.com/ericmj/decimal.git", tag: "v2.3.0", override: true},
      {:db_connection,
       git: "https://github.com/elixir-ecto/db_connection.git", tag: "v2.7.0", override: true},
      {:elixir_make,
       git: "https://github.com/elixir-lang/elixir_make.git", tag: "v0.9.0", override: true},
      {:cc_precompiler,
       git: "https://github.com/cocoa-xu/cc_precompiler.git", tag: "v0.1.9", override: true},
      {:stream_data,
       git: "https://github.com/whatyouhide/stream_data.git", tag: "v1.1.2", only: [:test, :dev]}
    ]
  end
end
