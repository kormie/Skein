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
      {:stream_data,
       git: "https://github.com/whatyouhide/stream_data.git", tag: "v1.1.2", only: [:test, :dev]}
    ]
  end
end
