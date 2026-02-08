defmodule SkeinLsp.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_lsp,
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
      extra_applications: [:logger],
      mod: {Skein.Lsp.Application, []}
    ]
  end

  defp deps do
    [
      {:skein_compiler, in_umbrella: true},
      {:gen_lsp, "~> 0.11"},
      {:typed_struct, "~> 0.3.0"},
      {:nimble_options, "~> 1.1"},
      {:schematic, "~> 0.2.1"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"}
    ]
  end
end
