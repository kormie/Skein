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
      {:nimble_parsec, git: "https://github.com/dashbitco/nimble_parsec.git", tag: "v1.4.2"},
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4"},
      {:stream_data, git: "https://github.com/whatyouhide/stream_data.git", tag: "v1.1.2",
       only: [:test, :dev]}
      # TODO: Add {:propcheck, "~> 1.4", only: [:test, :dev]} when hex.pm is accessible
      # PropCheck is needed for stateful/state-machine property testing (agents, runtime)
    ]
  end
end
