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
        applications:
          [
            skein_cli: :permanent,
            skein_compiler: :permanent,
            skein_runtime: :permanent,
            skein_lsp: :permanent
          ] ++ tui_applications(),
        steps: [&prune_vendored_raxol_tooling/1, :assemble, &Burrito.wrap/1],
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

  # Raxol and its dependency closure ship in the binary for
  # `skein trace --interactive` (issue #171) but must never start on the
  # plain CLI paths: every app below is loaded, not started, and the TUI
  # entry point boots them on demand via
  # Application.ensure_all_started(:raxol). Keep this list in sync with
  # raxol's dependency tree when bumping the dep.
  defp tui_applications do
    raxol_closure = [
      :raxol,
      :raxol_core,
      :raxol_terminal,
      :raxol_plugin,
      :raxol_mcp,
      :raxol_liveview,
      :raxol_sensor,
      :phoenix,
      :phoenix_html,
      :phoenix_live_view,
      :phoenix_pubsub,
      :phoenix_template,
      :plug_cowboy,
      :cowboy,
      :cowboy_telemetry,
      :cowlib,
      :ranch,
      :websock_adapter,
      :gettext,
      :expo,
      :makeup,
      :makeup_elixir,
      :nimble_parsec,
      :yaml_elixir,
      :yamerl,
      :toml,
      :uuid,
      :clipboard,
      :circular_buffer,
      :file_system,
      :telemetry_metrics,
      :telemetry_poller,
      :mnesia,
      :os_mon,
      :ssh
    ]

    for app <- raxol_closure, do: {app, :load}
  end

  # Two packaging fixups for raxol_terminal 2.4.0 (candidates for
  # upstream fixes, tracked on issue #171). The termbox2 NIF it vendors
  # never ships in our release — its .so never reaches priv/, so the
  # driver selects the pure-Elixir IOTerminal backend on every target.
  defp prune_vendored_raxol_tooling(%Mix.Release{} = release) do
    release
    |> prune_duplicated_tooling_modules()
    |> neutralize_raxol_terminal_nif_recompile()
  end

  # Fixup 1: the hex package includes the vendored termbox2_nif mix
  # project — with its bundled elixir_make dependency sources — under
  # lib/, so those modules compile into raxol_terminal.app and collide
  # with the real elixir_make app at release assembly ("Duplicated
  # modules"). Strip them from the compiled app before assembling; they
  # are mix build tooling and never run inside a release.
  defp prune_duplicated_tooling_modules(%Mix.Release{} = release) do
    build_lib = Path.join(Mix.Project.build_path(), "lib")
    terminal_app = Path.join([build_lib, "raxol_terminal", "ebin", "raxol_terminal.app"])
    make_app = Path.join([build_lib, "elixir_make", "ebin", "elixir_make.app"])

    with {:ok, terminal_props} <- consult_app(terminal_app),
         {:ok, make_props} <- consult_app(make_app) do
      make_modules = MapSet.new(app_modules(make_props))

      duplicated =
        Enum.filter(app_modules(terminal_props), &MapSet.member?(make_modules, &1))

      for module <- duplicated do
        File.rm(Path.join([build_lib, "raxol_terminal", "ebin", "#{module}.beam"]))
      end

      pruned = Keyword.update!(terminal_props, :modules, &(&1 -- duplicated))

      File.write!(
        terminal_app,
        :io_lib.format("~p.~n", [{:application, :raxol_terminal, pruned}])
      )

      update_in(release, [Access.key!(:applications), :raxol_terminal], fn
        nil -> nil
        props -> Keyword.update(props, :modules, [], &(&1 -- duplicated))
      end)
    else
      _ -> release
    end
  end

  defp consult_app(path) do
    case :file.consult(path) do
      {:ok, [{:application, _name, props}]} -> {:ok, props}
      _ -> :error
    end
  end

  defp app_modules(props), do: Keyword.get(props, :modules, [])

  # Fixup 2: Burrito's patch phase re-runs `make clean` / `make all` at
  # the root of every dep whose :compilers include :elixir_make, but
  # raxol_terminal's Makefile lives nested at lib/termbox2_nif/c_src
  # (elixir_make's make_cwd, which Burrito does not honor), so the
  # recompile fails the whole wrap. Nothing native ships from this app,
  # so a no-op root Makefile is the truthful per-target "recompile".
  defp neutralize_raxol_terminal_nif_recompile(%Mix.Release{} = release) do
    with path when is_binary(path) <- Mix.Project.deps_paths()[:raxol_terminal],
         makefile = Path.join(path, "Makefile"),
         false <- File.exists?(makefile) do
      File.write!(makefile, """
      # Written by the skein release build (see root mix.exs). Burrito
      # recompiles elixir_make deps from the dep root per target; this
      # package's real Makefile is nested under lib/termbox2_nif/c_src and
      # its NIF never ships in the release (the pure-Elixir IOTerminal
      # driver is used), so the per-target rebuild is a no-op.
      all:
      \t@true
      clean:
      \t@true
      """)
    end

    release
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
