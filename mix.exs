defmodule Skein.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.3", override: true}
    ]
  end

  defp releases do
    [
      skein: [
        applications: [
          skein_cli: :permanent,
          skein_compiler: :permanent,
          skein_runtime: :permanent
        ],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            macos: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
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
