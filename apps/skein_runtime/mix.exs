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
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:plug_crypto, "~> 2.1"},
      {:thousand_island, "~> 1.3"},
      {:hpax, "~> 1.0"},
      {:websock, "~> 0.5"},
      {:telemetry, "~> 1.3"},
      {:mime, "~> 2.0"},
      # Ecto + SQLite for storage backend
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:exqlite, "~> 0.24"},
      {:decimal, "~> 2.3"},
      {:db_connection, "~> 2.7"},
      {:elixir_make, "~> 0.9"},
      {:cc_precompiler, "~> 0.1.9"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:propcheck, "~> 1.4", only: [:test, :dev]}
    ]
  end
end
