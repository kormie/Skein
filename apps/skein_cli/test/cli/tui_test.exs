defmodule Skein.CLI.TuiTest do
  use ExUnit.Case, async: false

  alias Skein.CLI.Tui

  setup do
    original = System.get_env("SKEIN_NO_TUI")

    on_exit(fn ->
      if original do
        System.put_env("SKEIN_NO_TUI", original)
      else
        System.delete_env("SKEIN_NO_TUI")
      end
    end)

    System.delete_env("SKEIN_NO_TUI")
    :ok
  end

  describe "interactive?/2" do
    test "plain by default, argv untouched" do
      assert {false, ["--last", "5"]} = Tui.interactive?(["--last", "5"], tty: true)
    end

    test "--interactive engages on a TTY and is stripped from argv" do
      assert {true, []} = Tui.interactive?(["--interactive"], tty: true)

      assert {true, ["--kind", "http"]} =
               Tui.interactive?(["--interactive", "--kind", "http"], tty: true)
    end

    test "--interactive without a TTY falls back to plain output" do
      assert {false, []} = Tui.interactive?(["--interactive"], tty: false)
    end

    test "--no-tui wins over --interactive and both are stripped" do
      assert {false, []} = Tui.interactive?(["--interactive", "--no-tui"], tty: true)
      assert {false, ["--last", "3"]} = Tui.interactive?(["--no-tui", "--last", "3"], tty: true)
    end

    test "SKEIN_NO_TUI forces plain output" do
      System.put_env("SKEIN_NO_TUI", "1")
      assert {false, []} = Tui.interactive?(["--interactive"], tty: true)
    end

    test "empty or zero SKEIN_NO_TUI does not disable the TUI" do
      System.put_env("SKEIN_NO_TUI", "")
      assert {true, []} = Tui.interactive?(["--interactive"], tty: true)

      System.put_env("SKEIN_NO_TUI", "0")
      assert {true, []} = Tui.interactive?(["--interactive"], tty: true)
    end

    test "default TTY detection never raises" do
      assert {interactive, []} = Tui.interactive?(["--interactive"])
      assert is_boolean(interactive)
    end
  end

  describe "stdout_tty?/0" do
    test "returns a boolean" do
      assert is_boolean(Tui.stdout_tty?())
    end
  end
end
