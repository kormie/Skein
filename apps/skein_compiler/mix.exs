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
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4"}
    ]
  end
end
