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
      {:module, mod} -> {:ok, mod}
      {:error, _} = err -> err
    end
  end

  # ------------------------------------------------------------------
  # new — project scaffolding
  # ------------------------------------------------------------------

  @doc """
  Scaffolds a new Skein project at the given directory path.

  Creates a project structure with:
  - `skein.toml` — project configuration
  - `README.md` — project readme
  - `src/main.skein` — example source file
  - `test/main_test.skein` — example test file

  Returns `{:ok, project_dir}` on success.
  """
  @spec new([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def new([]) do
    {:error, "Usage: skein new <project-directory>"}
  end

  def new([project_dir | _]) do
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

      {:ok, project_dir}
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
    module_name = name |> Macro.camelize()

    """
    module #{module_name} {
      fn hello(name: String) -> String {
        "Hello, ${name}!"
      }
    }
    """
  end

  defp main_test_skein(name) do
    module_name = name |> Macro.camelize()

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
  def build([]) do
    {:error, "Usage: skein build <project-directory>"}
  end

  def build([project_dir | _]) do
    project_dir = Path.expand(project_dir)
    skein_files = discover_skein_files(project_dir, "src")

    if skein_files == [] do
      {:error, "No .skein files found in #{project_dir}/src/"}
    else
      {modules, failed} =
        skein_files
        |> Enum.reduce({[], []}, fn file, {mods, fails} ->
          case Compiler.compile_file(file) do
            {:module, mod} ->
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

  Returns `{:ok, %{total: n, passed: n, failed: n, files: n, compile_errors: n, results: [...]}}`.
  """
  @spec test_all([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def test_all([]) do
    {:error, "Usage: skein test <project-directory>"}
  end

  def test_all([project_dir | _]) do
    project_dir = Path.expand(project_dir)

    skein_files =
      (discover_skein_files(project_dir, "test") ++
         discover_skein_files(project_dir, "src"))
      |> Enum.uniq()

    if skein_files == [] do
      {:error, "No .skein files found in #{project_dir}"}
    else
      {all_results, compile_errors} =
        skein_files
        |> Enum.reduce({[], 0}, fn file, {results_acc, err_count} ->
          case Compiler.compile_file(file) do
            {:module, mod} ->
              file_results = run_tests_for_file(mod, file)
              {results_acc ++ file_results, err_count}

            {:error, _} ->
              {results_acc, err_count + 1}
          end
        end)

      passed = Enum.count(all_results, &(&1.status == :passed))
      failed = Enum.count(all_results, &(&1.status == :failed))
      files_tested = all_results |> Enum.map(& &1.file) |> Enum.uniq() |> length()

      {:ok,
       %{
         total: length(all_results),
         passed: passed,
         failed: failed,
         files: files_tested,
         compile_errors: compile_errors,
         results: all_results
       }}
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
  def run([]) do
    {:error, "Usage: skein run <project-directory> [--port <port>]"}
  end

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
  def run_config([]) do
    {:error, "Usage: skein run <project-directory> [--port <port>]"}
  end

  def run_config(args) do
    {project_dir, opts} = parse_run_args(args)
    project_dir = Path.expand(project_dir)
    port = Keyword.get(opts, :port, 4000)

    skein_files = discover_skein_files(project_dir, "src")

    if skein_files == [] do
      {:error, "No .skein files found in #{project_dir}/src/"}
    else
      modules =
        skein_files
        |> Enum.reduce([], fn file, acc ->
          case Compiler.compile_file(file) do
            {:module, mod} -> [mod | acc]
            {:error, _} -> acc
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

  defp parse_run_args(args) do
    {project_dir, rest} =
      case args do
        ["--" <> _ | _] -> {".", args}
        [dir | rest] -> {dir, rest}
        [] -> {".", []}
      end

    opts = parse_flags(rest, [])
    {project_dir, opts}
  end

  defp parse_flags(["--port", port_str | rest], acc) do
    parse_flags(rest, [{:port, String.to_integer(port_str)} | acc])
  end

  defp parse_flags([_ | rest], acc), do: parse_flags(rest, acc)
  defp parse_flags([], acc), do: acc

  # ------------------------------------------------------------------
  # trace — view recent trace spans
  # ------------------------------------------------------------------

  @doc """
  Returns recent trace spans from the runtime trace store.

  Options:
  - `--last <n>` — Number of traces to return (default: 10)
  - `--kind <kind>` — Filter by span kind (e.g., "http", "llm", "tool")

  Returns `{:ok, %{spans: [...], count: n}}`.
  """
  @spec trace([String.t()]) :: {:ok, map()}
  def trace(args) do
    alias Skein.Runtime.Trace

    Trace.init()

    opts = parse_trace_args(args)
    limit = Keyword.get(opts, :last, 10)
    kind_filter = Keyword.get(opts, :kind, nil)

    spans = Trace.recent_spans(max(limit, 1))

    spans =
      if kind_filter do
        kind_atom = String.to_existing_atom(kind_filter)
        Enum.filter(spans, &(&1.kind == kind_atom))
      else
        spans
      end

    spans = Enum.take(spans, limit)

    {:ok, %{spans: spans, count: length(spans)}}
  end

  defp parse_trace_args(args), do: parse_trace_flags(args, [])

  defp parse_trace_flags(["--last", n | rest], acc) do
    parse_trace_flags(rest, [{:last, String.to_integer(n)} | acc])
  end

  defp parse_trace_flags(["--kind", kind | rest], acc) do
    parse_trace_flags(rest, [{:kind, kind} | acc])
  end

  defp parse_trace_flags([_ | rest], acc), do: parse_trace_flags(rest, acc)
  defp parse_trace_flags([], acc), do: acc

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

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
