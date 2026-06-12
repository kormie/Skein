defmodule SkeinCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_cli,
      version: "1.0.0-rc.2",
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
      {:burrito, "~> 1.5"},
      # TUI framework spike (issue #171). Pinned to patch level: young
      # upstream with monthly releases — widen deliberately, not by accident.
      # runtime: false keeps plain CLI paths from auto-starting the raxol
      # closure; the release ships it :load (see root mix.exs) and the TUI
      # entry point starts it on demand.
      {:raxol, "~> 2.4.0", runtime: false}
    ]
  end
end
