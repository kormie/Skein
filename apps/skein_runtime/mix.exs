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
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4"},
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
      {:stream_data,
       git: "https://github.com/whatyouhide/stream_data.git", tag: "v1.1.2", only: [:test, :dev]}
    ]
  end
end
