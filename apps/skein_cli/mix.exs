defmodule SkeinCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_cli,
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
      {:skein_compiler, in_umbrella: true},
      {:skein_runtime, in_umbrella: true}
    ]
  end
end
