defmodule Skein.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "1.0.0-rc.2",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),

      # ExDoc
      name: "Skein",
      source_url: "https://github.com/kormie/Skein",
      homepage_url: "https://kormie.github.io/Skein/",
      docs: docs()
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.3", override: true},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Skein.Compiler",
      output: "docs/site/public/api",
      formatters: ["html"],
      extras: [
        "docs/SKEIN_SPEC.md": [title: "Language Specification"],
        "docs/ARCHITECTURE.md": [title: "Architecture"],
        "docs/ROADMAP.md": [title: "Roadmap"]
      ],
      groups_for_modules: [
        "Standard Library": ~r/Skein\.Runtime\.Stdlib\./,
        Compiler: ~r/Skein\.(Compiler|Lexer|Parser|Analyzer|AST|CodeGen|Error)/,
        Runtime: ~r/Skein\.Runtime\./,
        CLI: ~r/Skein\.CLI/,
        LSP: ~r/Skein\.Lsp/
      ],
      nest_modules_by_prefix: [
        Skein.Runtime.Stdlib,
        Skein.Runtime,
        Skein.CodeGen,
        Skein.Lsp
      ],
      before_closing_head_tag: &before_closing_head_tag/1
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <style>
      /* Link back to main docs site */
      .sidebar-projectLink a::after {
        content: " — API Reference";
      }
    </style>
    """
  end

  defp before_closing_head_tag(_), do: ""

  defp releases do
    [
      skein: [
        applications: [
          skein_cli: :permanent,
          skein_compiler: :permanent,
          skein_runtime: :permanent,
          skein_lsp: :permanent,
          # runtime: false deps are excluded from releases unless listed;
          # :load ships them started-on-demand (Bedrock credential chain).
          aws_credentials: :load,
          jsx: :load,
          eini: :load,
          iso8601: :load
        ],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            macos: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # The aliases route through Skein.CLI.Main.dispatch/1 — the same
  # printing and exit-code path as the standalone binary — so failures
  # are reported and exit non-zero instead of being silently discarded
  # (issue #198).
  defp aliases do
    [
      "skein.compile": ["run -e 'Skein.CLI.Main.dispatch([\"compile\" | System.argv()])'"],
      "skein.new": ["run -e 'Skein.CLI.Main.dispatch([\"new\" | System.argv()])'"],
      "skein.build": ["run -e 'Skein.CLI.Main.dispatch([\"build\" | System.argv()])'"],
      "skein.test": ["run -e 'Skein.CLI.Main.dispatch([\"test\" | System.argv()])'"],
      "skein.run": ["run -e 'Skein.CLI.Main.dispatch([\"run\" | System.argv()])'"],
      "skein.trace": ["run -e 'Skein.CLI.Main.dispatch([\"trace\" | System.argv()])'"],
      docs: ["docs"]
    ]
  end
end
