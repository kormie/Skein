defmodule SkeinCompiler.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_compiler,
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:propcheck, "~> 1.4", only: [:test, :dev]},
      {:libgraph, "~> 0.13", override: true, only: [:test, :dev]}
    ]
  end
end
