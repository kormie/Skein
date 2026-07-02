defmodule Skein.CLI.BenchReplayTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Bench

  @moduledoc """
  Replays the checked-in agent-writability recordings (#320) against the
  current compiler.

  Like the dogfood corpus, this pins recorded real-agent output as a
  conformance surface: every recorded task converged to green when it was
  recorded, so a task that stops converging means the language or the
  diagnostics moved under the recording — either fix the regression or
  re-record (`mix skein.bench -- --live`) in the same PR and account for
  the metric change.
  """

  @recordings Path.expand("../../../../../conformance/writability/recordings.json", __DIR__)

  test "every recorded task still converges to green" do
    assert {:ok, report} = Bench.run_replay(@recordings)

    assert report.summary.failed == [],
           "recorded tasks no longer converge: #{inspect(report.summary.non_converged_codes)}"

    assert report.summary.tasks == length(Skein.CLI.Bench.Tasks.suite())
  end

  test "the recorded quality bar holds: most tasks compile first-try" do
    assert {:ok, report} = Bench.run_replay(@recordings)

    # The recorded run scored 9/12 first-try. A compiler change that
    # breaks formerly-clean first generations shows up here before it
    # ships; improving beyond the floor is always fine.
    assert report.summary.first_try_rate >= 0.5,
           "first-try rate collapsed to #{report.summary.first_try_rate}"
  end
end
