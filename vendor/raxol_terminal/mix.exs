# Vendored from raxol_terminal 2.4.0 (https://github.com/DROOdotFOO/raxol,
# MIT) with Skein-local patches — see SKEIN_PATCHES.md in this directory.
# Used as a path override until the patches land upstream (issue #171).
defmodule RaxolTerminal.MixProject do
  use Mix.Project

  @version "2.4.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol_terminal,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18 or ~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Vendored raxol_terminal with Skein patches (see SKEIN_PATCHES.md)",
      name: "Raxol Terminal",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:raxol_core, "~> 2.4"},
      {:uuid, "~> 1.1"},
      {:jason, "~> 1.4"}
    ]
  end
end
