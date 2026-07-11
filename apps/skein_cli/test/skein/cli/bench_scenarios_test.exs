defmodule Skein.CLI.BenchScenariosTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Bench
  alias Skein.CLI.Bench.Tasks

  @scenarios Path.expand("../../../../../conformance/writability/scenarios/*.md", __DIR__)
  @recordings Path.expand("../../../../../conformance/writability/recordings.json", __DIR__)

  test "the 1.0 writability gate has checked-in scenario briefs for the thesis surfaces" do
    names =
      @scenarios
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               "agent_lifecycle",
               "tool_call",
               "capability_environment",
               "replay_golden",
               "http_starts_agent",
               "llm_json_typed"
             ]),
             names
           )
  end

  test "the executable suite covers typed llm.json and the checked-in recordings" do
    task = Enum.find(Tasks.suite(), &(&1.id == "llm_effect"))
    assert task.name == "Typed LLM JSON output"
    assert task.prompt =~ "llm.json[PoemCheck]"

    assert {:ok, report} = Bench.run_replay(@recordings, tasks: [task])
    assert report.summary.failed == []
  end
end
