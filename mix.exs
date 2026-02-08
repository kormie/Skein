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
    [
      {:decimal, git: "https://github.com/ericmj/decimal.git", tag: "v2.3.0", override: true}
    ]
  end

  defp aliases do
    [
      "skein.compile": ["run -e 'Skein.CLI.compile(System.argv())'"],
      "skein.new": ["run -e 'Skein.CLI.new(System.argv())'"],
      "skein.build": ["run -e 'Skein.CLI.build(System.argv())'"],
      "skein.test": ["run -e 'Skein.CLI.test_all(System.argv())'"],
      "skein.run": ["run -e 'Skein.CLI.run(System.argv())'"],
      "skein.trace": ["run -e 'Skein.CLI.trace(System.argv())'"]
    ]
  end
end
