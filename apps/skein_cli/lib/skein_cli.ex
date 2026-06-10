defmodule Skein.CLI do
  @moduledoc """
  CLI entry point for Skein tooling.

  Provides commands for compiling, building, testing, running, and
  tracing Skein projects and source files.

  ## Commands

  - `compile` — Compile a single .skein file to BEAM bytecode
  - `new` — Scaffold a new Skein project
  - `build` — Compile all .skein files in a project
  - `test` — Compile and run tests in a single .skein file
  - `test_all` — Discover and run all tests across a project
  - `run` — Start a Skein service with HTTP handlers
  - `trace` — View recent trace spans
  """

  alias Skein.CLI.AgentsMd
  alias Skein.Compiler

  # ------------------------------------------------------------------
  # compile — single file compilation
  # ------------------------------------------------------------------

  @doc """
  Compiles a .skein file to BEAM bytecode and loads the resulting module.

  Returns `{:ok, module}` on success or `{:error, reason}` on failure.
  """
  @spec compile([String.t()]) :: {:ok, module()} | {:error, term()}
  def compile([]) do
    {:error, "Usage: skein compile <file.skein>"}
  end

  def compile([path | _]) do
    case Compiler.compile_file(path) do
      {:module, mod} ->
        register_tools(mod)
        {:ok, mod}

      {:error, _} = err ->
        err
    end
  end

  # Every CLI path that loads a compiled module registers its declared
  # tools so cross-module tool.call(...) resolves at runtime.
  defp register_tools(mod), do: Skein.Runtime.Tool.register_module(mod)

  # ------------------------------------------------------------------
  # new — project scaffolding
  # ------------------------------------------------------------------

  @doc """
  Scaffolds a new Skein project at the given directory path.

  Creates a project structure with:
  - `skein.toml` — project configuration
  - `README.md` — project readme
  - `AGENTS.md` — Skein primer for coding agents (skip with `--no-agents`)
  - `CLAUDE.md` — one-line pointer to AGENTS.md
  - `src/main.skein` — example source file
  - `test/main_test.skein` — example test file

  Returns `{:ok, project_dir}` on success.
  """
  @spec new([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def new([]) do
    {:error, "Usage: skein new <project-directory> [--no-agents]"}
  end

  def new(args) do
    {flags, positional} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    with :ok <- validate_new_flags(flags),
         [project_dir | _] <- positional do
      do_new(project_dir, "--no-agents" not in flags)
    else
      [] -> {:error, "Usage: skein new <project-directory> [--no-agents]"}
      {:error, _} = err -> err
    end
  end

  defp validate_new_flags(flags) do
    case Enum.reject(flags, &(&1 == "--no-agents")) do
      [] -> :ok
      [flag | _] -> {:error, "Unknown option: #{flag} (run 'skein help' for usage)"}
    end
  end

  defp do_new(project_dir, write_agents_md?) do
    project_dir = Path.expand(project_dir)
    name = Path.basename(project_dir)

    if File.exists?(Path.join(project_dir, "skein.toml")) do
      {:error, "Project already exists at #{project_dir} — skein.toml already exists"}
    else
      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, "src"))
      File.mkdir_p!(Path.join(project_dir, "test"))

      File.write!(Path.join(project_dir, "skein.toml"), skein_toml(name))
      File.write!(Path.join(project_dir, "README.md"), readme(name))
      File.write!(Path.join(project_dir, "src/main.skein"), main_skein(name))
      File.write!(Path.join(project_dir, "test/main_test.skein"), main_test_skein(name))

      if write_agents_md? do
        File.write!(Path.join(project_dir, "AGENTS.md"), AgentsMd.render())
        File.write!(Path.join(project_dir, "CLAUDE.md"), AgentsMd.claude_md_pointer())
      end

      {:ok, project_dir}
    end
  end

  # ------------------------------------------------------------------
  # agents — create or refresh AGENTS.md in an existing project
  # ------------------------------------------------------------------

  @doc """
  Creates `AGENTS.md` in a project (default: current directory) or
  updates only the generated block of an existing one. User content
  outside the marker comments is preserved. Regeneration is idempotent
  for a given toolchain version.

  Returns `{:ok, %{path: path, action: :created | :updated}}`.
  """
  @spec agents([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def agents(args) do
    with {:ok, project_dir, _opts} <- parse_project_args(args, %{}) do
      project_dir = Path.expand(project_dir)

      if File.dir?(project_dir) do
        AgentsMd.upsert(project_dir)
      else
        {:error, "No such directory: #{project_dir}"}
      end
    end
  end

  defp skein_toml(name) do
    """
    [project]
    name = "#{name}"
    version = "0.1.0"

    [build]
    src = "src"
    test = "test"
    """
  end

  defp readme(name) do
    """
    # #{name}

    A Skein service.

    ## Getting Started

    ```bash
    # Build the project
    skein build

    # Run tests
    skein test

    # Start the service
    skein run
    ```
    """
  end

  defp main_skein(name) do
    module_name = module_name_from(name)

    """
    module #{module_name} {
      fn hello(name: String) -> String {
        "Hello, ${name}!"
      }
    }
    """
  end

  defp main_test_skein(name) do
    module_name = module_name_from(name)

    """
    module #{module_name}Test {
      fn hello(name: String) -> String {
        "Hello, ${name}!"
      }

      test "hello returns greeting" {
        assert hello("World") == "Hello, World!"
      }
    }
    """
  end

  # Project directory names like "my-app" or "my app" must still produce a
  # valid Skein module name (Macro.camelize only splits on underscores).
  defp module_name_from(name) do
    base =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> Macro.camelize()

    if base =~ ~r/^[A-Z]/, do: base, else: "Skein#{base}"
  end

  # ------------------------------------------------------------------
  # build — compile all .skein files in a project
  # ------------------------------------------------------------------

  @doc """
  Compiles all `.skein` files in a project's `src/` directory tree.

  Walks `<project_dir>/src/` recursively, compiles each `.skein` file,
  and returns an aggregate result. Compilation errors in one file do not
  prevent other files from being compiled.

  Returns `{:ok, %{compiled: n, errors: n, modules: [...], failed: [...]}}`.
  """
  @spec build([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def build(args) do
    with {:ok, project_dir, opts} <- parse_project_args(args, build_flag_spec()) do
      project_dir = Path.expand(project_dir)
      output_dir = Keyword.get(opts, :output, nil)
      skein_files = discover_skein_files(project_dir, "src")

      if skein_files == [] do
        no_files_error(project_dir, ["src"])
      else
        if output_dir do
          build_to_disk(skein_files, output_dir)
        else
          build_in_memory(skein_files)
        end
      end
    end
  end

  defp build_in_memory(skein_files) do
    {modules, failed} =
      skein_files
      |> Enum.reduce({[], []}, fn file, {mods, fails} ->
        case Compiler.compile_file(file) do
          {:module, mod} ->
            register_tools(mod)
            {[mod | mods], fails}

          {:error, errors} ->
            {mods, [%{file: file, errors: errors} | fails]}
        end
      end)

    {:ok,
     %{
       compiled: length(modules),
       errors: length(failed),
       modules: Enum.reverse(modules),
       failed: Enum.reverse(failed)
     }}
  end

  defp build_to_disk(skein_files, output_dir) do
    output_dir = Path.expand(output_dir)
    File.mkdir_p!(output_dir)

    {modules, beam_files, failed} =
      skein_files
      |> Enum.reduce({[], [], []}, fn file, {mods, beams, fails} ->
        case Compiler.compile_to_binary(file) do
          {:ok, module_name, beam_binary} ->
            # Write .beam file to output directory
            beam_filename = "#{module_name}.beam"
            beam_path = Path.join(output_dir, beam_filename)
            File.write!(beam_path, beam_binary)

            # Also load into VM for immediate use
            :code.load_binary(module_name, ~c"#{beam_path}", beam_binary)
            register_tools(module_name)

            {[module_name | mods], [beam_path | beams], fails}

          {:error, errors} ->
            {mods, beams, [%{file: file, errors: errors} | fails]}
        end
      end)

    {:ok,
     %{
       compiled: length(modules),
       errors: length(failed),
       modules: Enum.reverse(modules),
       beam_files: Enum.reverse(beam_files),
       failed: Enum.reverse(failed),
       output_dir: output_dir
     }}
  end

  defp build_flag_spec do
    %{"--output" => fn dir -> {:ok, {:output, dir}} end}
  end

  # ------------------------------------------------------------------
  # test (single file) — existing behavior
  # ------------------------------------------------------------------

  @doc """
  Compiles a .skein file and runs all test declarations within it.

  Returns `{:ok, %{total: n, passed: n, failed: n, results: [...]}}`.
  """
  @spec test([String.t()]) :: {:ok, map()} | {:error, term()}
  def test([]) do
    {:error, "Usage: skein test <file.skein>"}
  end

  def test([path | _]) do
    case compile([path]) do
      {:ok, mod} ->
        run_tests_for_module(mod)

      {:error, _} = err ->
        err
    end
  end

  # ------------------------------------------------------------------
  # test_all — project-wide test runner
  # ------------------------------------------------------------------

  @doc """
  Discovers and runs all tests across a Skein project.

  Searches both `src/` and `test/` directories for `.skein` files,
  compiles each, and runs any test declarations found. Files that
  fail to compile are tracked separately.

  Returns `{:ok, %{total: n, passed: n, failed: n, files: n, compile_errors: n,
  compile_failed: [...], results: [...]}}`. `compile_failed` carries the
  structured errors for each file that did not compile, so callers can
  surface them instead of silently skipping the file.
  """
  @spec test_all([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def test_all(args) do
    with {:ok, project_dir, _opts} <- parse_project_args(args, %{}) do
      project_dir = Path.expand(project_dir)

      skein_files =
        (discover_skein_files(project_dir, "test") ++
           discover_skein_files(project_dir, "src"))
        |> Enum.uniq()

      if skein_files == [] do
        no_files_error(project_dir, ["src", "test"])
      else
        {all_results, compile_failed} =
          skein_files
          |> Enum.reduce({[], []}, fn file, {results_acc, failed_acc} ->
            case Compiler.compile_file(file) do
              {:module, mod} ->
                register_tools(mod)
                file_results = run_tests_for_file(mod, file)
                {results_acc ++ file_results, failed_acc}

              {:error, errors} ->
                {results_acc, [%{file: file, errors: errors} | failed_acc]}
            end
          end)

        compile_failed = Enum.reverse(compile_failed)
        passed = Enum.count(all_results, &(&1.status == :passed))
        failed = Enum.count(all_results, &(&1.status == :failed))
        files_tested = all_results |> Enum.map(& &1.file) |> Enum.uniq() |> length()

        {:ok,
         %{
           total: length(all_results),
           passed: passed,
           failed: failed,
           files: files_tested,
           compile_errors: length(compile_failed),
           compile_failed: compile_failed,
           results: all_results
         }}
      end
    end
  end

  # ------------------------------------------------------------------
  # run — start service locally
  # ------------------------------------------------------------------

  @doc """
  Compiles a Skein project and starts an HTTP server for any handlers found.

  Options:
  - `--port <n>` — Port to listen on (default: 4000)

  Returns `{:ok, pid}` where `pid` is the server process.
  """
  @spec run([String.t()]) :: {:ok, pid()} | {:error, String.t()}
  def run(args) do
    case run_config(args) do
      {:ok, config} ->
        Skein.Runtime.Server.start_link(module: config.module, port: config.port)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Parses run arguments and compiles the project, returning the config
  without starting the server. Useful for testing option parsing.

  Returns `{:ok, %{module: mod, port: n}}` or `{:error, reason}`.
  """
  @spec run_config([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def run_config(args) do
    with {:ok, project_dir, opts} <- parse_project_args(args, run_flag_spec()) do
      do_run_config(project_dir, opts)
    end
  end

  defp do_run_config(project_dir, opts) do
    project_dir = Path.expand(project_dir)
    port = Keyword.get(opts, :port, 4000)

    skein_files = discover_skein_files(project_dir, "src")

    if skein_files == [] do
      no_files_error(project_dir, ["src"])
    else
      modules =
        skein_files
        |> Enum.reduce([], fn file, acc ->
          case Compiler.compile_file(file) do
            {:module, mod} ->
              register_tools(mod)
              [mod | acc]

            {:error, _} ->
              acc
          end
        end)

      handler_module =
        Enum.find(modules, fn mod ->
          function_exported?(mod, :__handlers__, 0) and mod.__handlers__() != []
        end)

      if handler_module do
        {:ok, %{module: handler_module, port: port}}
      else
        {:error, "No handlers found in compiled modules"}
      end
    end
  end

  defp run_flag_spec do
    %{
      "--port" => fn port_str ->
        case Integer.parse(port_str) do
          {port, ""} when port in 1..65535 ->
            {:ok, {:port, port}}

          _ ->
            {:error,
             "Invalid value for --port: '#{port_str}' (expected an integer from 1 to 65535)"}
        end
      end
    }
  end

  # ------------------------------------------------------------------
  # trace — view recent trace spans
  # ------------------------------------------------------------------

  @doc """
  Returns recent trace spans from the runtime trace store.

  Options:
  - `--last <n>` — Number of traces to return (default: 10)
  - `--kind <kind>` — Filter by span kind (e.g., "http", "llm", "tool")

  Returns `{:ok, %{spans: [...], count: n}}` or `{:error, reason}` for
  malformed flag values.
  """
  @spec trace([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def trace(args) do
    alias Skein.Runtime.Trace

    Trace.init()

    with {:ok, opts} <- parse_trace_args(args) do
      limit = Keyword.get(opts, :last, 10)
      kind_filter = Keyword.get(opts, :kind, nil)

      spans = Trace.recent_spans(max(limit, 1))

      spans =
        if kind_filter do
          # Compare as strings rather than converting the filter to an atom:
          # String.to_existing_atom/1 raises for unknown kinds, and
          # String.to_atom/1 would mint atoms from user input.
          Enum.filter(spans, &(Atom.to_string(&1.kind) == kind_filter))
        else
          spans
        end

      spans = Enum.take(spans, limit)

      {:ok, %{spans: spans, count: length(spans)}}
    end
  end

  defp parse_trace_args(args), do: parse_trace_flags(args, [])

  defp parse_trace_flags(["--last", n | rest], acc) do
    case Integer.parse(n) do
      {count, ""} when count > 0 ->
        parse_trace_flags(rest, [{:last, count} | acc])

      _ ->
        {:error, "Invalid value for --last: '#{n}' (expected a positive integer)"}
    end
  end

  defp parse_trace_flags(["--kind", kind | rest], acc) do
    parse_trace_flags(rest, [{:kind, kind} | acc])
  end

  defp parse_trace_flags(["-" <> _ = flag | _], _acc),
    do: {:error, "Unknown option: #{flag} (run 'skein help' for usage)"}

  defp parse_trace_flags([arg | _], _acc), do: {:error, "Unexpected argument: #{arg}"}
  defp parse_trace_flags([], acc), do: {:ok, acc}

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  # Parses "[project-dir] [flags]" argument lists. The first non-flag token
  # is the project directory (defaulting to "."); flags are looked up in
  # `flag_spec`, a map of flag name to a value-parser function. Unknown
  # flags are an error rather than being silently treated as a directory.
  defp parse_project_args(args, flag_spec) do
    do_parse_project_args(args, flag_spec, nil, [])
  end

  defp do_parse_project_args([], _spec, dir, opts), do: {:ok, dir || ".", Enum.reverse(opts)}

  defp do_parse_project_args([arg | rest], spec, dir, opts) do
    cond do
      Map.has_key?(spec, arg) ->
        case rest do
          [value | rest_after_value] ->
            with {:ok, parsed} <- spec[arg].(value) do
              do_parse_project_args(rest_after_value, spec, dir, [parsed | opts])
            end

          [] ->
            {:error, "Missing value for #{arg}"}
        end

      String.starts_with?(arg, "-") ->
        {:error, "Unknown option: #{arg} (run 'skein help' for usage)"}

      dir == nil ->
        do_parse_project_args(rest, spec, arg, opts)

      true ->
        {:error, "Unexpected argument: #{arg}"}
    end
  end

  # Reports that no sources were found, pointing at stray top-level .skein
  # files when that's the likely cause (projects keep sources in src/).
  defp no_files_error(project_dir, searched_subdirs) do
    searched = Enum.map_join(searched_subdirs, " or ", &(Path.join(project_dir, &1) <> "/"))
    root_files = project_dir |> Path.join("*.skein") |> Path.wildcard() |> Enum.sort()

    case root_files do
      [] ->
        {:error, "No .skein files found in #{searched}"}

      files ->
        names = Enum.map_join(files, ", ", &Path.basename/1)

        {:error,
         "No .skein files found in #{searched} - found #{names} in the project root. " <>
           "Skein projects keep sources in src/ (or compile a single file with 'skein compile <file>')"}
    end
  end

  defp discover_skein_files(project_dir, subdir) do
    dir = Path.join(project_dir, subdir)

    if File.dir?(dir) do
      dir
      |> Path.join("**/*.skein")
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  defp run_tests_for_module(mod) do
    tests =
      if function_exported?(mod, :__tests__, 0) do
        mod.__tests__()
      else
        []
      end

    results =
      Enum.map(tests, fn test_meta ->
        %{description: desc, fn: test_fn} = test_meta
        kind = Map.get(test_meta, :kind, :test)

        try do
          apply(mod, test_fn, [])
          %{description: desc, status: :passed, kind: kind}
        rescue
          e ->
            %{description: desc, status: :failed, kind: kind, error: Exception.message(e)}
        end
      end)

    passed = Enum.count(results, &(&1.status == :passed))
    failed = Enum.count(results, &(&1.status == :failed))

    {:ok, %{total: length(results), passed: passed, failed: failed, results: results}}
  end

  defp run_tests_for_file(mod, file) do
    tests =
      if function_exported?(mod, :__tests__, 0) do
        mod.__tests__()
      else
        []
      end

    Enum.map(tests, fn test_meta ->
      %{description: desc, fn: test_fn} = test_meta
      kind = Map.get(test_meta, :kind, :test)

      try do
        apply(mod, test_fn, [])
        %{description: desc, status: :passed, file: file, kind: kind}
      rescue
        e ->
          %{
            description: desc,
            status: :failed,
            file: file,
            kind: kind,
            error: Exception.message(e)
          }
      end
    end)
  end
end
