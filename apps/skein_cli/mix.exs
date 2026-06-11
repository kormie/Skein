defmodule SkeinCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_cli,
      version: "0.2.0",
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
      extra_applications: [:logger],
      mod: {Skein.CLI.Main, []}
    ]
  end

  defp deps do
    [
      {:skein_compiler, in_umbrella: true},
      {:skein_runtime, in_umbrella: true},
      {:skein_lsp, in_umbrella: true},
      {:burrito, "~> 1.5"}
    ]
  end
end
