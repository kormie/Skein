defmodule Skein.CLI.Tui do
  @moduledoc """
  Gate for interactive terminal UI surfaces (issue #171).

  Interactive mode is strictly opt-in (`--interactive`) and only engages
  when stdout is a real TTY. `--no-tui` or a non-empty `SKEIN_NO_TUI`
  environment variable force the plain line-oriented output, so CI,
  scripts, and coding agents always get the stable parseable output.

  `skein mcp` and `skein lsp` own stdout for their wire protocols and
  never route through this gate.
  """

  @tui_flags ["--interactive", "--no-tui"]

  @doc """
  Decides whether a command invocation should run its interactive TUI.

  Returns `{interactive?, argv}` with the TUI flags stripped from `argv`
  so downstream flag parsing is unaffected.

  Options:
  - `tty:` — override TTY detection (used by tests)
  """
  @spec interactive?([String.t()], keyword()) :: {boolean(), [String.t()]}
  def interactive?(argv, opts \\ []) do
    {tui_args, rest} = Enum.split_with(argv, &(&1 in @tui_flags))

    interactive =
      "--interactive" in tui_args and
        "--no-tui" not in tui_args and
        not no_tui_env?() and
        Keyword.get_lazy(opts, :tty, &stdout_tty?/0)

    {interactive, rest}
  end

  @doc """
  Runs the interactive trace explorer for an already-fetched trace result.

  Falls back to the plain rendering until the TUI application lands.
  """
  @spec run_trace(%{spans: [map()], count: non_neg_integer()}) :: :ok
  def run_trace(result) do
    IO.puts(Skein.CLI.Render.trace_plain(result))
  end

  @doc """
  True when stdout is attached to a terminal device.
  """
  @spec stdout_tty?() :: boolean()
  def stdout_tty? do
    Code.ensure_loaded?(:prim_tty) and
      function_exported?(:prim_tty, :isatty, 1) and
      :prim_tty.isatty(:stdout) == true
  end

  defp no_tui_env? do
    System.get_env("SKEIN_NO_TUI", "") not in ["", "0"]
  end
end
