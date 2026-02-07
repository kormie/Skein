defmodule Skein.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      "skein.compile": ["run -e 'Skein.CLI.compile(System.argv())'"],
      "skein.spec": ["run -e 'Skein.CLI.spec(System.argv())'"]
    ]
  end
end
