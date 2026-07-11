defmodule Skein.CLI.Bench do
  @moduledoc """
  Agent-writability benchmark (#320): measure the P6 pitch instead of
  asserting it.

  For each task in the fixed suite (`Skein.CLI.Bench.Tasks`), the harness
  runs a generate-compile-fix loop:

  1. ask a generator (an LLM in live mode, a recording in replay mode)
     for a complete Skein module,
  2. compile it with `Skein.Compiler.check_string/2`,
  3. mechanically apply every machine-applicable fix
     (`span` + `edit_kind` + `fix_code`, via `Skein.Error.Edit.apply_fix/2`),
  4. feed the remaining structured diagnostics (JSON, exactly what agents
     consume) back to the generator, and iterate to green or a cap.

  The report carries the P6 metrics: first-try compile rate, mean
  iterations-to-green, how much work the machine-applicable fixes did,
  and which diagnostics failed to converge (those are P6 bugs — file
  them).

  Replay mode (`run_replay/2`, the default of `main/1`) is deterministic
  and headless: it re-runs the recorded generations through the *current*
  compiler, so release-readiness re-measures RC quality without LLM
  calls, and a recorded solution that stops compiling is a caught
  regression. Live runs (`--live`) need `ANTHROPIC_API_KEY` and refresh
  the recordings.
  """

  alias Skein.CLI.Bench.History
  alias Skein.CLI.Bench.Recordings
  alias Skein.CLI.Bench.Tasks
  alias Skein.Error.Edit

  @default_max_iterations 4
  @default_recordings_path "conformance/writability/recordings.json"
  @default_history_path "conformance/writability/history.jsonl"
  @default_chart_path "docs/site/public/writability-history.svg"
  @default_model "claude-opus-4-8"
  # Applying one fix can reveal or re-span others; bound the fixpoint.
  @max_mechanical_applications 10

  @typedoc """
  Produces the generator response for a task iteration.

  Receives the task, the 1-based iteration, and the system/user prompts;
  returns the raw response text (the harness extracts the fenced code).
  """
  @type generator ::
          (Tasks.task(), pos_integer(), String.t(), String.t() ->
             {:ok, String.t()} | {:error, String.t()})

  # -- Entry points ----------------------------------------------------------

  @doc """
  Runs the benchmark with an explicit generator.

  Options: `:generator` (required), `:tasks` (default the full suite),
  `:max_iterations` (default #{@default_max_iterations}), `:mode` and
  `:model` (report metadata).

  Returns the report plus the raw responses per task (for recording).
  """
  @spec run(keyword()) :: %{report: map(), responses: %{String.t() => [String.t()]}}
  def run(opts) do
    generator = Keyword.fetch!(opts, :generator)
    tasks = Keyword.get(opts, :tasks, Tasks.suite())
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    system = system_prompt()

    results = Enum.map(tasks, &run_task(&1, generator, system, max_iterations))

    report = %{
      version: 1,
      mode: Keyword.get(opts, :mode, "custom"),
      model: Keyword.get(opts, :model),
      max_iterations: max_iterations,
      summary: summarize(results),
      tasks: Enum.map(results, &Map.delete(&1, :responses))
    }

    responses = Map.new(results, &{&1.id, Enum.reverse(&1.responses)})
    %{report: report, responses: responses}
  end

  @doc "Runs the benchmark by replaying recorded generations (deterministic)."
  @spec run_replay(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run_replay(recordings_path, opts \\ []) do
    with {:ok, recordings} <- Recordings.load(recordings_path) do
      %{report: report} =
        run(
          Keyword.merge(opts,
            generator: Recordings.replay_generator(recordings),
            mode: "replay",
            model: recordings.model
          )
        )

      {:ok, report}
    end
  end

  @doc """
  Runs the benchmark against the live Anthropic backend and records it.

  Needs `ANTHROPIC_API_KEY`. Unless `:record_to` is nil, writes the
  recordings (so replay runs stay deterministic), appends the run's
  metrics to the history file, and regenerates the trend chart the README
  and docs site embed.
  """
  @spec run_live(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run_live(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    if Skein.Runtime.Llm.AnthropicBackend.get_api_key() in [nil, ""] do
      {:error, "live mode needs ANTHROPIC_API_KEY (or :anthropic_api_key app config)"}
    else
      %{report: report, responses: responses} =
        run(Keyword.merge(opts, generator: live_generator(model), mode: "live", model: model))

      case Keyword.get(opts, :record_to, @default_recordings_path) do
        nil ->
          {:ok, report}

        path ->
          recorded_at = DateTime.utc_now() |> DateTime.to_iso8601()

          with :ok <- Recordings.save(path, responses, model: model, recorded_at: recorded_at),
               :ok <-
                 History.record(report,
                   history_path: Keyword.get(opts, :history_to, @default_history_path),
                   chart_path: Keyword.get(opts, :chart_to, @default_chart_path),
                   recorded_at: recorded_at
                 ) do
            {:ok, report}
          end
      end
    end
  end

  @doc """
  CLI entry point (`mix skein.bench`). Pass flags after a `--` separator
  so `mix run` does not consume them: `mix skein.bench -- --live`.

  Flags: `--live` (default is replay), `--recordings PATH`,
  `--report PATH` (write the JSON report), `--max-iterations N`,
  `--task ID` (repeatable — subset of the suite), `--model NAME`,
  `--no-record` (live mode without refreshing the recordings).

  Exits 0 when every task converges to green, 1 otherwise.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case parse_argv(argv, %{
           live: false,
           record: true,
           recordings: @default_recordings_path,
           report: nil,
           max_iterations: @default_max_iterations,
           task_ids: [],
           model: @default_model
         }) do
      {:error, message} ->
        IO.puts(:stderr, "skein.bench: #{message}")
        System.halt(2)

      {:ok, opts} ->
        run_opts = [max_iterations: opts.max_iterations] ++ task_filter(opts.task_ids)

        result =
          if opts.live do
            record_to = if opts.record, do: opts.recordings, else: nil
            run_live(run_opts ++ [model: opts.model, record_to: record_to])
          else
            run_replay(opts.recordings, run_opts)
          end

        case result do
          {:error, message} ->
            IO.puts(:stderr, "skein.bench: #{message}")
            System.halt(2)

          {:ok, report} ->
            if opts.report do
              File.mkdir_p!(Path.dirname(opts.report))
              File.write!(opts.report, Jason.encode!(report, pretty: true) <> "\n")
            end

            IO.puts(render_summary(report))
            System.halt(if report.summary.failed == [], do: 0, else: 1)
        end
    end
  end

  # -- The generate-compile-fix loop -----------------------------------------

  defp run_task(task, generator, system, max_iterations) do
    initial = %{
      id: task.id,
      status: :failed,
      first_try: false,
      iterations: 0,
      mechanically_converged: false,
      generator_error: nil,
      iterations_detail: [],
      non_converged_codes: [],
      responses: []
    }

    iterate(task, generator, system, initial_prompt(task), 1, max_iterations, initial)
  end

  defp iterate(task, generator, system, user, iteration, max_iterations, acc) do
    case generator.(task, iteration, system, user) do
      {:error, message} ->
        finalize(%{acc | generator_error: message})

      {:ok, response} ->
        source = extract_code(response)
        acc = %{acc | iterations: iteration, responses: [response | acc.responses]}
        {errors, warnings} = check(source, task)

        {fixed_source, applied, remaining} =
          if errors == [], do: {source, [], []}, else: mechanical_pass(source, errors, task)

        detail = %{
          iteration: iteration,
          error_codes: codes(errors),
          warning_codes: codes(warnings),
          mechanical_fixes: applied,
          error_codes_after_fixes: codes(remaining)
        }

        acc = %{acc | iterations_detail: acc.iterations_detail ++ [detail]}

        cond do
          errors == [] ->
            finalize(%{acc | status: :green, first_try: iteration == 1})

          remaining == [] ->
            finalize(%{acc | status: :green, mechanically_converged: true})

          iteration == max_iterations ->
            finalize(%{acc | non_converged_codes: codes(remaining)})

          true ->
            feedback = feedback_prompt(fixed_source, remaining)
            iterate(task, generator, system, feedback, iteration + 1, max_iterations, acc)
        end
    end
  end

  defp finalize(acc) do
    if acc.status == :failed and acc.non_converged_codes == [] do
      last_codes =
        case List.last(acc.iterations_detail) do
          nil -> []
          detail -> detail.error_codes_after_fixes
        end

      %{acc | non_converged_codes: last_codes}
    else
      acc
    end
  end

  defp check(source, task) do
    case Skein.Compiler.check_string(source, task.id <> ".skein") do
      {:ok, %{errors: [], warnings: warnings}} ->
        case compile_load_and_run(source, task) do
          :ok -> {[], warnings}
          {:error, error} -> {[error], warnings}
        end

      {:ok, %{errors: errors, warnings: warnings}} ->
        {errors, warnings}

      {:error, message} ->
        {[internal_error(message, task)], []}
    end
  end

  defp compile_load_and_run(source, task) do
    case Skein.Compiler.compile_string(source) do
      {:module, mod} ->
        run_declared_tests(mod, task)

      {:error, errors} when is_list(errors) ->
        message =
          "compile/load failed after a clean check: " <>
            inspect(Enum.map(errors, &{&1.code, &1.message}))

        {:error, internal_error(message, task)}

      {:error, message} ->
        {:error,
         internal_error("compile/load failed after a clean check: " <> to_string(message), task)}
    end
  end

  defp run_declared_tests(mod, task) do
    if function_exported?(mod, :__tests__, 0) do
      mod.__tests__()
      |> Enum.each(fn %{fn: name} -> apply(mod, name, []) end)
    end

    :ok
  rescue
    exception ->
      {:error, internal_error("generated test failed: " <> Exception.message(exception), task)}
  catch
    kind, reason ->
      {:error, internal_error("generated test failed: " <> inspect({kind, reason}), task)}
  end

  # check_string only returns {:error, message} for file-system problems,
  # which a string compile can't hit — but never let the loop crash on it.
  defp internal_error(message, task) do
    %Skein.Error{
      code: "INTERNAL",
      severity: :error,
      message: to_string(message),
      location: %{file: task.id <> ".skein", line: 1, col: 1}
    }
  end

  defp codes(diagnostics), do: diagnostics |> Enum.map(& &1.code) |> Enum.uniq()

  # Apply machine-applicable fixes to a fixpoint: one fix per round (fixes
  # move spans), recompile, repeat while any error still applies.
  defp mechanical_pass(
         source,
         errors,
         task,
         applied \\ [],
         rounds \\ @max_mechanical_applications
       )

  defp mechanical_pass(source, errors, _task, applied, 0),
    do: {source, Enum.reverse(applied), errors}

  defp mechanical_pass(source, errors, task, applied, rounds) do
    applicable =
      Enum.find_value(errors, fn error ->
        case Edit.apply_fix(source, error) do
          {:ok, new_source} when new_source != source -> {error.code, new_source}
          _ -> nil
        end
      end)

    case applicable do
      nil ->
        {source, Enum.reverse(applied), errors}

      {code, new_source} ->
        case check(new_source, task) do
          {[], _warnings} ->
            {new_source, Enum.reverse([code | applied]), []}

          {remaining, _warnings} ->
            mechanical_pass(new_source, remaining, task, [code | applied], rounds - 1)
        end
    end
  end

  # -- Prompts ----------------------------------------------------------------

  @doc false
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are an expert Skein programmer. Skein is a small language for cloud
    services on the BEAM. Use only the public language specification below as
    the authority for syntax and semantics:

    #{public_spec()}

    Write exactly one complete, compiling Skein source file for the user's
    task. Output ONLY the Skein source inside a single ```skein fence —
    no prose before or after it.
    """
  end

  defp public_spec do
    [File.cwd!(), "docs", "SKEIN_SPEC.md"]
    |> Path.join()
    |> File.read!()
  end

  defp initial_prompt(%{prompt: prompt}), do: prompt

  defp feedback_prompt(source, errors) do
    diagnostics = errors |> Skein.Error.to_json_list() |> Jason.encode!(pretty: true)

    """
    The Skein compiler rejected your program with these structured
    diagnostics (JSON):

    #{diagnostics}

    Current source:

    ```skein
    #{source}
    ```

    Return the complete corrected Skein source file. Output ONLY the source
    inside a single ```skein fence.
    """
  end

  @doc """
  Extracts the Skein source from a generator response.

  Takes the last fenced code block when present (a chatty response's final
  fence is the corrected program), otherwise the trimmed raw text.
  """
  @spec extract_code(String.t()) :: String.t()
  def extract_code(response) do
    case Regex.scan(~r/```(?:skein)?[ \t]*\n(.*?)```/s, response, capture: :all_but_first) do
      [] -> String.trim(response)
      fences -> fences |> List.last() |> hd() |> String.trim()
    end
  end

  # -- Live generator ----------------------------------------------------------

  defp live_generator(model) do
    fn _task, _iteration, system, user ->
      case Skein.Runtime.Llm.AnthropicBackend.chat(model, system, user) do
        {:ok, response} -> {:ok, response.text}
        {:error, error} -> {:error, inspect(error)}
      end
    end
  end

  # -- Report -------------------------------------------------------------------

  defp summarize(results) do
    green = Enum.filter(results, &(&1.status == :green))
    failed = results |> Enum.filter(&(&1.status == :failed)) |> Enum.map(& &1.id)
    first_try = Enum.count(results, & &1.first_try)

    mean_iterations =
      case green do
        [] -> nil
        green -> Float.round(Enum.sum(Enum.map(green, & &1.iterations)) / length(green), 2)
      end

    %{
      tasks: length(results),
      green: length(green),
      failed: failed,
      first_try: first_try,
      first_try_rate:
        if(results == [], do: 0.0, else: Float.round(first_try / length(results), 3)),
      mean_iterations_to_green: mean_iterations,
      mechanical_fix_applications:
        results
        |> Enum.flat_map(& &1.iterations_detail)
        |> Enum.map(&length(&1.mechanical_fixes))
        |> Enum.sum(),
      non_converged_codes:
        results
        |> Enum.filter(&(&1.status == :failed and &1.non_converged_codes != []))
        |> Map.new(&{&1.id, &1.non_converged_codes})
    }
  end

  defp render_summary(report) do
    summary = report.summary

    task_lines =
      Enum.map(report.tasks, fn task ->
        status =
          case task do
            %{status: :green, first_try: true} -> "green (first try)"
            %{status: :green, mechanically_converged: true} -> "green (mechanical fixes)"
            %{status: :green, iterations: n} -> "green (#{n} iterations)"
            %{non_converged_codes: codes} -> "FAILED (#{Enum.join(codes, ", ")})"
          end

        "  #{String.pad_trailing(task.id, 20)} #{status}"
      end)

    """
    Agent-writability benchmark (#{report.mode}#{if report.model, do: ", " <> report.model}) — \
    #{summary.green}/#{summary.tasks} green
    #{Enum.join(task_lines, "\n")}

    first-try compile rate:    #{summary.first_try}/#{summary.tasks} (#{trunc(summary.first_try_rate * 100)}%)
    mean iterations to green:  #{summary.mean_iterations_to_green || "n/a"}
    mechanical fixes applied:  #{summary.mechanical_fix_applications}\
    #{if summary.failed != [], do: "\nnon-converged: " <> inspect(summary.non_converged_codes), else: ""}
    """
  end

  # -- Argv ----------------------------------------------------------------------

  defp task_filter([]), do: []

  defp task_filter(ids) do
    [tasks: Enum.filter(Tasks.suite(), &(&1.id in ids))]
  end

  defp parse_argv([], opts) do
    if opts.task_ids != [] and task_filter(opts.task_ids) == [tasks: []] do
      {:error, "no suite task matches: #{Enum.join(opts.task_ids, ", ")}"}
    else
      {:ok, opts}
    end
  end

  defp parse_argv(["--live" | rest], opts), do: parse_argv(rest, %{opts | live: true})
  defp parse_argv(["--no-record" | rest], opts), do: parse_argv(rest, %{opts | record: false})

  defp parse_argv(["--recordings", path | rest], opts),
    do: parse_argv(rest, %{opts | recordings: path})

  defp parse_argv(["--report", path | rest], opts), do: parse_argv(rest, %{opts | report: path})
  defp parse_argv(["--model", model | rest], opts), do: parse_argv(rest, %{opts | model: model})

  defp parse_argv(["--task", id | rest], opts),
    do: parse_argv(rest, %{opts | task_ids: opts.task_ids ++ [id]})

  defp parse_argv(["--max-iterations", n | rest], opts) do
    case Integer.parse(n) do
      {value, ""} when value >= 1 -> parse_argv(rest, %{opts | max_iterations: value})
      _ -> {:error, "--max-iterations expects a positive integer, got #{inspect(n)}"}
    end
  end

  defp parse_argv([flag | _], _opts), do: {:error, "unknown flag #{inspect(flag)}"}
end
