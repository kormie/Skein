defmodule Skein.CLI.BenchTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Bench
  alias Skein.CLI.Bench.Recordings
  alias Skein.CLI.Bench.Tasks

  @moduletag :tmp_dir

  # A generator that plays a fixed script per task id: iteration N returns
  # the Nth element. Overruns return an error, like an exhausted recording.
  defp scripted(script) do
    fn task, iteration, _system, _user ->
      case script |> Map.fetch!(task.id) |> Enum.at(iteration - 1) do
        nil -> {:error, "script exhausted for #{task.id} at iteration #{iteration}"}
        response -> {:ok, response}
      end
    end
  end

  defp task(id) do
    %{id: id, name: id, prompt: "write module #{id}", context: nil}
  end

  @green_module """
  module Fine {
    fn double(n: Int) -> Int { n * 2 }

    test "doubles" { assert double(2) == 4 }
  }
  """

  # E0020 return-type mismatch: no machine-applicable fix, so convergence
  # requires another generation (unlike, say, a misspelling E0010).
  @broken_module """
  module Broken {
    fn f() -> Int {
      "not an int"
    }
  }
  """

  # E0012 with a machine-applicable insert_line fix that alone reaches green.
  @fixable_module """
  module Stash {
    fn stash() -> String {
      memory.put("k", "v")!
    }
  }
  """

  # Compiles clean but with a W0001 unused-binding warning.
  @warning_module """
  module Warny {
    fn f() -> String {
      let unused = 1
      "ok"
    }
  }
  """

  describe "task suite" do
    test "spans the surface with unique, well-formed tasks" do
      suite = Tasks.suite()

      assert length(suite) >= 12
      ids = Enum.map(suite, & &1.id)
      assert ids == Enum.uniq(ids)

      for task <- suite do
        assert task.id =~ ~r/^[a-z][a-z0-9_]*$/
        assert is_binary(task.prompt) and task.prompt != ""
        assert is_binary(task.name) and task.name != ""
        assert is_nil(task.context) or (is_binary(task.context) and task.context != "")
      end
    end
  end

  describe "extract_code/1" do
    test "returns the last fenced block when the response wraps code in fences" do
      response = """
      Here is a first attempt:

      ```skein
      module Old { }
      ```

      Actually, use this corrected version:

      ```skein
      module New {
        fn f() -> Int { 1 }
      }
      ```
      """

      assert Bench.extract_code(response) =~ "module New"
      refute Bench.extract_code(response) =~ "module Old"
    end

    test "returns trimmed raw text when there is no fence" do
      assert Bench.extract_code("  module Bare { }\n") == "module Bare { }"
    end
  end

  describe "run/1" do
    test "a clean first generation is green on the first try" do
      %{report: report} =
        Bench.run(
          generator: scripted(%{"only" => [@green_module]}),
          tasks: [task("only")],
          max_iterations: 4
        )

      assert [result] = report.tasks
      assert result.status == :green
      assert result.first_try
      assert result.iterations == 1
      refute result.mechanically_converged
      assert [%{iteration: 1, error_codes: [], warning_codes: []}] = result.iterations_detail

      assert report.summary.tasks == 1
      assert report.summary.green == 1
      assert report.summary.failed == []
      assert report.summary.first_try == 1
      assert report.summary.first_try_rate == 1.0
      assert report.summary.mean_iterations_to_green == 1.0
    end

    test "warnings are recorded but do not block green" do
      %{report: report} =
        Bench.run(
          generator: scripted(%{"warny" => [@warning_module]}),
          tasks: [task("warny")]
        )

      assert [result] = report.tasks
      assert result.status == :green
      assert result.first_try
      assert [%{warning_codes: ["W0001"]}] = result.iterations_detail
    end

    test "structured diagnostics feed back and converge on the second iteration" do
      parent = self()

      generator = fn _task, iteration, _system, user ->
        send(parent, {:prompt, iteration, user})

        case iteration do
          1 -> {:ok, @broken_module}
          2 -> {:ok, @green_module}
        end
      end

      %{report: report} =
        Bench.run(generator: generator, tasks: [task("converges")], max_iterations: 4)

      assert [result] = report.tasks
      assert result.status == :green
      refute result.first_try
      assert result.iterations == 2

      assert [first, second] = result.iterations_detail
      assert "E0020" in first.error_codes
      assert second.error_codes == []

      # The second prompt must carry the structured diagnostics and the source.
      assert_received {:prompt, 2, feedback}
      assert feedback =~ "E0020"
      assert feedback =~ "fix_hint"
      assert feedback =~ "module Broken"

      assert report.summary.mean_iterations_to_green == 2.0
      assert report.summary.first_try_rate == 0.0
    end

    test "machine-applicable fixes converge a task without another generation" do
      %{report: report} =
        Bench.run(
          generator: scripted(%{"fixable" => [@fixable_module]}),
          tasks: [task("fixable")]
        )

      assert [result] = report.tasks
      assert result.status == :green
      assert result.iterations == 1
      refute result.first_try
      assert result.mechanically_converged

      assert [detail] = result.iterations_detail
      assert "E0012" in detail.error_codes
      assert "E0012" in detail.mechanical_fixes
      assert detail.error_codes_after_fixes == []

      assert report.summary.mechanical_fix_applications == 1
    end

    test "a task that never converges fails at the cap with its final codes" do
      %{report: report} =
        Bench.run(
          generator: scripted(%{"stuck" => List.duplicate(@broken_module, 3)}),
          tasks: [task("stuck")],
          max_iterations: 3
        )

      assert [result] = report.tasks
      assert result.status == :failed
      assert result.iterations == 3
      assert "E0020" in result.non_converged_codes

      assert report.summary.failed == ["stuck"]
      assert report.summary.non_converged_codes == %{"stuck" => result.non_converged_codes}
      assert report.summary.mean_iterations_to_green == nil
    end

    test "a generator error fails the task" do
      generator = fn _task, _iteration, _system, _user -> {:error, "backend down"} end

      %{report: report} = Bench.run(generator: generator, tasks: [task("dead")])

      assert [result] = report.tasks
      assert result.status == :failed
      assert result.generator_error == "backend down"
      assert report.summary.failed == ["dead"]
    end

    test "collects raw responses per task for recording" do
      %{responses: responses} =
        Bench.run(
          generator: scripted(%{"converges" => [@broken_module, @green_module]}),
          tasks: [task("converges")],
          max_iterations: 4
        )

      assert responses == %{"converges" => [@broken_module, @green_module]}
    end
  end

  describe "recordings" do
    test "save/load round-trips and replay reproduces the run", %{tmp_dir: tmp_dir} do
      tasks = [task("a"), task("b")]
      script = %{"a" => [@green_module], "b" => [@broken_module, @green_module]}

      %{report: live_report, responses: responses} =
        Bench.run(generator: scripted(script), tasks: tasks, max_iterations: 4)

      path = Path.join(tmp_dir, "recordings.json")
      assert :ok = Recordings.save(path, responses, model: "test-model")

      assert {:ok, recordings} = Recordings.load(path)
      assert recordings.model == "test-model"

      %{report: replay_report} =
        Bench.run(
          generator: Recordings.replay_generator(recordings),
          tasks: tasks,
          max_iterations: 4,
          mode: "replay",
          model: recordings.model
        )

      assert replay_report.tasks == live_report.tasks
      assert replay_report.summary == live_report.summary
      assert replay_report.mode == "replay"
    end

    test "an exhausted recording fails the task instead of hanging", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "recordings.json")
      # Recording only covers iteration 1, but the task needs a second one.
      assert :ok = Recordings.save(path, %{"stuck" => [@broken_module]}, model: "test-model")
      assert {:ok, recordings} = Recordings.load(path)

      %{report: report} =
        Bench.run(
          generator: Recordings.replay_generator(recordings),
          tasks: [task("stuck")],
          max_iterations: 4
        )

      assert [result] = report.tasks
      assert result.status == :failed
      assert result.generator_error =~ "exhausted"
    end

    test "loading a missing file is a structured error" do
      assert {:error, message} = Recordings.load("/nonexistent/recordings.json")
      assert message =~ "recordings"
    end
  end
end
