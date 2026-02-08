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
      {:gen_lsp, git: "https://github.com/elixir-tools/gen_lsp.git", tag: "v0.11.3"},
      {:typed_struct,
       git: "https://github.com/ejpcmac/typed_struct.git", tag: "v0.3.0", override: true},
      {:nimble_options,
       git: "https://github.com/dashbitco/nimble_options.git", tag: "v1.1.1", override: true},
      {:schematic,
       git: "https://github.com/mhanberg/schematic.git", tag: "v0.2.1", override: true},
      {:jason, git: "https://github.com/michalmuskala/jason.git", tag: "v1.4.4", override: true},
      {:telemetry,
       git: "https://github.com/beam-telemetry/telemetry.git", tag: "v1.3.0", override: true}
    ]
  end
end
