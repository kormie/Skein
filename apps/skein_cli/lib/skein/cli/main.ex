defmodule Skein.CLI.Main do
  @moduledoc """
  Application entry point for the Skein CLI binary.

  When running as a Burrito-wrapped standalone binary, this module
  reads command-line arguments via `Burrito.Util.Args.argv/0` and
  dispatches to the appropriate `Skein.CLI` command. When running
  under Mix (development), it starts normally without dispatching
  since Mix aliases handle command routing.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: Skein.CLI.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if release?() do
        args = Burrito.Util.Args.argv()
        dispatch(args)
      end

      {:ok, pid}
    end
  end

  # Mix is not loaded in releases — this distinguishes dev from Burrito binary
  defp release? do
    not Code.ensure_loaded?(Mix)
  end

  @doc """
  Dispatches CLI arguments to the appropriate Skein.CLI command.

  This is the main routing function that maps subcommands to their
  handler functions.
  """
  @spec dispatch([String.t()]) :: no_return()
  def dispatch(["compile" | rest]) do
    case Skein.CLI.compile(rest) do
      {:ok, mod} ->
        IO.puts("Compiled: #{inspect(mod)}")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["new" | rest]) do
    case Skein.CLI.new(rest) do
      {:ok, dir} ->
        IO.puts("Created project at #{dir}")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["build" | rest]) do
    case Skein.CLI.build(rest) do
      {:ok, result} ->
        IO.puts("Build complete: #{result.compiled} compiled, #{result.errors} errors")

        if result.errors > 0 do
          for f <- result.failed do
            IO.puts(:stderr, "  Failed: #{f.file}")
          end

          System.halt(1)
        else
          System.halt(0)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["test" | rest]) do
    case Skein.CLI.test_all(rest) do
      {:ok, result} ->
        IO.puts("Tests: #{result.passed} passed, #{result.failed} failed (#{result.total} total)")

        if result.failed > 0 do
          for r <- result.results, r.status == :failed do
            IO.puts(:stderr, "  FAIL: #{r.description} — #{Map.get(r, :error, "unknown")}")
          end

          System.halt(1)
        else
          System.halt(0)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["run" | rest]) do
    case Skein.CLI.run(rest) do
      {:ok, _pid} ->
        # Keep the process alive — the server runs in the supervision tree
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["trace" | rest]) do
    case Skein.CLI.trace(rest) do
      {:ok, result} ->
        IO.puts("Traces (#{result.count}):")

        for span <- result.spans do
          IO.puts("  [#{span.kind}] #{span.name} (#{span.duration_ms}ms)")
        end

        System.halt(0)
    end
  end

  def dispatch(["version" | _]) do
    IO.puts("skein #{version()}")
    System.halt(0)
  end

  def dispatch(["help" | _]) do
    print_usage()
    System.halt(0)
  end

  def dispatch([unknown | _]) do
    IO.puts(:stderr, "Unknown command: #{unknown}\n")
    print_usage()
    System.halt(1)
  end

  def dispatch([]) do
    print_usage()
    System.halt(0)
  end

  defp print_usage do
    IO.puts("""
    Skein #{version()} — AI-native language for the BEAM

    Usage: skein <command> [options]

    Commands:
      compile <file.skein>       Compile a single .skein file
      new <project-dir>          Scaffold a new Skein project
      build <project-dir>        Compile all .skein files in a project
      test <project-dir>         Run all tests in a project
      run <project-dir>          Start the Skein service
      trace [options]            View recent trace spans
      version                    Print version
      help                       Show this help

    Options:
      build --output <dir>       Write .beam files to directory
      run --port <port>          Server port (default: 4000)
      trace --last <n>           Number of traces (default: 10)
      trace --kind <kind>        Filter by span kind
    """)
  end

  defp version do
    Application.spec(:skein_cli, :vsn) |> to_string()
  end

  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_list(reason),
    do: Enum.map_join(reason, "\n", &format_error/1)

  defp format_error(%{message: msg, location: %{file: f, line: l}}) do
    "#{f}:#{l}: #{msg}"
  end

  defp format_error(reason), do: inspect(reason)
end
