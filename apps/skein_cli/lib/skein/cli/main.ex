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
  def dispatch(["check" | rest]), do: dispatch(["compile" | rest])

  def dispatch(["compile" | rest]) do
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.compile(rest)

    if json? do
      emit_json(Skein.CLI.Json.compile(result))
    else
      render_compile(result)
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
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.build(rest)

    if json? do
      emit_json(Skein.CLI.Json.build(result))
    else
      render_build(result)
    end
  end

  def dispatch(["test" | rest]) do
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.test_all(rest)

    if json? do
      emit_json(Skein.CLI.Json.test(result))
    else
      render_test(result)
    end
  end

  def dispatch(["run", "status" | rest]) do
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.run_status(rest)

    if json? do
      emit_json(Skein.CLI.Json.run_status(result))
    else
      render_run_status(result)
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

  def dispatch(["eventstore", "query" | rest]), do: dispatch(["event-store", "query" | rest])

  def dispatch(["EventStore", "query" | rest]), do: dispatch(["event-store", "query" | rest])

  def dispatch(["event-store", "query" | rest]) do
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.event_store(rest)

    if json? do
      emit_json(Skein.CLI.Json.event_store(result))
    else
      render_event_store(result)
    end
  end

  def dispatch(["trace", "query" | rest]), do: dispatch(["trace" | rest])

  def dispatch(["trace" | rest]) do
    {json?, rest} = take_json_flag(rest)
    result = Skein.CLI.trace(rest)

    if json? do
      emit_json(Skein.CLI.Json.trace(result))
    else
      render_trace(result)
    end
  end

  def dispatch(["agents" | rest]) do
    case Skein.CLI.agents(rest) do
      {:ok, %{path: path, action: :created}} ->
        IO.puts("Created #{path}")
        System.halt(0)

      {:ok, %{path: path, action: :updated}} ->
        IO.puts("Updated generated block in #{path}")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{format_error(reason)}")
        System.halt(1)
    end
  end

  def dispatch(["mcp" | _]) do
    # The MCP server owns stdout — route logging to stderr so JSON-RPC
    # frames stay clean (same as the lsp subcommand).
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error},
      formatter: Logger.default_formatter()
    })

    Skein.CLI.Mcp.serve()
    System.halt(0)
  end

  def dispatch(["lsp" | _]) do
    # The LSP owns stdout — route logging to stderr so protocol frames
    # stay clean.
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error},
      formatter: Logger.default_formatter()
    })

    {:ok, _pid} = SkeinLsp.start()
    Process.sleep(:infinity)
  end

  def dispatch(["completions" | rest]) do
    case Skein.CLI.completions(rest) do
      {:ok, script} ->
        IO.puts(script)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
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

  # ------------------------------------------------------------------
  # Output: plain (default) vs --json (#284)
  # ------------------------------------------------------------------

  # `--json` is presentation only: it never reaches the Skein.CLI command
  # functions (which return structured results regardless), so the same result
  # renders as either plain text or a versioned JSON envelope. The flag may
  # appear anywhere in the command's argument list.
  defp take_json_flag(args) do
    {json_flags, rest} = Enum.split_with(args, &(&1 == "--json"))
    {json_flags != [], rest}
  end

  # Write the JSON envelope to stdout and exit with the envelope's success
  # signal mirrored into the process exit code (0 when ok, 1 otherwise).
  defp emit_json(%{ok: ok?} = envelope) do
    IO.write(Skein.CLI.Json.encode(envelope))
    System.halt(if(ok?, do: 0, else: 1))
  end

  defp render_compile({:ok, mod, warnings}) do
    for w <- warnings do
      IO.puts(:stderr, "Warning: #{format_error(w)}")
    end

    IO.puts("Compiled: #{inspect(mod)}")
    System.halt(0)
  end

  defp render_compile({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp render_build({:ok, result}) do
    IO.puts("Build complete: #{result.compiled} compiled, #{result.errors} errors")

    if result.errors > 0 do
      for f <- result.failed do
        IO.puts(:stderr, format_error(f.errors))
      end

      System.halt(1)
    else
      System.halt(0)
    end
  end

  defp render_build({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp render_test({:ok, result}) do
    IO.puts("Tests: #{result.passed} passed, #{result.failed} failed (#{result.total} total)")

    for r <- result.results, r.status == :failed do
      location =
        case Map.get(r, :location) do
          nil -> ""
          loc -> " (#{loc})"
        end

      IO.puts(:stderr, "  FAIL: #{r.description}#{location} — #{Map.get(r, :error, "unknown")}")
    end

    if result.compile_errors > 0 do
      IO.puts(:stderr, "#{result.compile_errors} file(s) failed to compile and were not tested:")

      for f <- result.compile_failed do
        IO.puts(:stderr, format_error(f.errors))
      end
    end

    if result.failed > 0 or result.compile_errors > 0 do
      System.halt(1)
    else
      System.halt(0)
    end
  end

  defp render_test({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp render_run_status({:ok, status}) do
    IO.puts("Run status: #{status.state} (#{status.modules_count} module(s), port #{status.port})")
    System.halt(0)
  end

  defp render_run_status({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp render_event_store({:ok, result}) do
    IO.puts(Skein.CLI.Json.encode(Skein.CLI.Json.event_store({:ok, result})))
    System.halt(0)
  end

  defp render_event_store({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp render_trace({:ok, result}) do
    # Plain, byte-stable rendering through the pure framework-neutral
    # renderer (#284). MCP/LSP/non-TTY output never routes through a TUI.
    IO.write(Skein.CLI.Render.trace(result))
    System.halt(0)
  end

  defp render_trace({:error, reason}) do
    IO.puts(:stderr, "Error: #{format_error(reason)}")
    System.halt(1)
  end

  defp print_usage do
    IO.puts(usage_text())
  end

  @doc """
  The skein help text. Public so the completion drift test can assert
  every listed subcommand appears in the generated completion script.
  """
  @spec usage_text() :: String.t()
  def usage_text do
    """
    Skein #{version()} — AI-native language for the BEAM

    Usage: skein <command> [options]

    Commands:
      compile <file.skein>       Compile a single .skein file
      check <file.skein>         Alias for compile (JSON schema: skein.compile/v1)
      new <project-dir>          Scaffold a new Skein project
      build [project-dir]        Compile all .skein files in a project (default: .)
      test [project-dir]         Run all tests in a project (default: .)
      run [project-dir]          Start the Skein service (default: .)
      run status [project-dir]   Inspect compiled service modules without serving
      agents [project-dir]       Create or refresh AGENTS.md (default: .)
      mcp                        Start the MCP server (stdio, for coding agents)
      lsp                        Start the language server (stdio, for editors)
      trace [options]            View recent trace spans
      trace query [options]      Alias for trace
      event-store query [opts]   Query unified runtime EventStore
      completions zsh            Print the zsh completion script
      version                    Print version
      help                       Show this help

    Options:
      new --backend <name>       LLM backend in skein.toml: anthropic (default),
                                 bedrock, openai_compatible, test
      new --no-agents            Skip generating AGENTS.md / CLAUDE.md
      new --no-git               Skip git init (a .gitignore is always written)
      build --output <dir>       Write .beam files to directory
      run --port <port>          Server port (default: 4000)
      run --no-persist           Skip SQLite event persistence (default:
                                 events persist to .skein/events.db)
      trace --last <n>           Number of traces (default: 10)
      trace --kind <kind>        Filter by span kind
      --json                     Machine-readable JSON output (compile, build,
                                 test, trace, run status, event-store query) — a
                                 versioned, documented envelope
    """
  end

  defp version do
    Application.spec(:skein_cli, :vsn) |> to_string()
  end

  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) when is_list(reason),
    do: Enum.map_join(reason, "\n", &format_error/1)

  defp format_error(%{message: msg, location: %{file: f, line: l}} = error) do
    base = "#{f}:#{l}: #{msg}"

    case Map.get(error, :fix_hint) do
      hint when is_binary(hint) and hint != "" -> base <> "\n  hint: #{hint}"
      _ -> base
    end
  end

  defp format_error(reason), do: inspect(reason)
end
