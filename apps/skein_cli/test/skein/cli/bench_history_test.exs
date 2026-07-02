defmodule Skein.CLI.Bench.HistoryTest do
  use ExUnit.Case, async: true

  alias Skein.CLI.Bench.History

  @moduletag :tmp_dir

  defp report(green, first_try, mean) do
    %{
      model: "test-model",
      summary: %{
        tasks: 12,
        green: green,
        failed: [],
        first_try: first_try,
        first_try_rate: Float.round(first_try / 12, 3),
        mean_iterations_to_green: mean,
        mechanical_fix_applications: 0,
        non_converged_codes: %{}
      }
    }
  end

  describe "append/3 and load/1" do
    test "round-trips entries in order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nested/history.jsonl")

      assert :ok = History.append(path, report(10, 8, 1.2), "2026-07-01T10:00:00Z")
      assert :ok = History.append(path, report(12, 9, 1.17), "2026-07-02T10:00:00Z")

      assert {:ok, [first, second]} = History.load(path)
      assert first.recorded_at == "2026-07-01T10:00:00Z"
      assert first.green == 10
      assert first.first_try == 8
      assert second.recorded_at == "2026-07-02T10:00:00Z"
      assert second.tasks == 12
      assert second.mean_iterations_to_green == 1.17
      assert second.model == "test-model"
    end

    test "a missing history file loads as empty" do
      assert {:ok, []} = History.load("/nonexistent/history.jsonl")
    end
  end

  describe "render_svg/1" do
    test "charts green and first-try rates as two labeled series" do
      entries = [
        %{
          recorded_at: "2026-07-01T10:00:00Z",
          model: "m",
          tasks: 12,
          green: 10,
          first_try: 8,
          mean_iterations_to_green: 1.2
        },
        %{
          recorded_at: "2026-07-02T10:00:00Z",
          model: "m",
          tasks: 12,
          green: 12,
          first_try: 9,
          mean_iterations_to_green: 1.17
        }
      ]

      svg = History.render_svg(entries)

      assert svg =~ "<svg"
      assert svg =~ "</svg>"
      # Two series, each with a polyline and per-run markers.
      assert length(String.split(svg, "<polyline")) == 3
      assert length(String.split(svg, "<circle")) == 5
      # Legend/direct labels carry identity in ink, not color-alone.
      assert svg =~ "tasks green"
      assert svg =~ "first-try compile"
      # Latest values are directly labeled.
      assert svg =~ "100%"
      assert svg =~ "75%"
      # Native tooltips per marker.
      assert svg =~ "<title>"
    end

    test "a single run still renders" do
      entries = [
        %{
          recorded_at: "2026-07-02T10:00:00Z",
          model: "m",
          tasks: 12,
          green: 12,
          first_try: 9,
          mean_iterations_to_green: 1.17
        }
      ]

      svg = History.render_svg(entries)
      assert svg =~ "<svg"
      assert svg =~ "100%"
    end
  end

  describe "record/3" do
    test "appends the run and regenerates the chart", %{tmp_dir: tmp_dir} do
      history = Path.join(tmp_dir, "history.jsonl")
      chart = Path.join(tmp_dir, "chart.svg")

      assert :ok =
               History.record(report(12, 9, 1.17),
                 history_path: history,
                 chart_path: chart,
                 recorded_at: "2026-07-02T10:00:00Z"
               )

      assert {:ok, [entry]} = History.load(history)
      assert entry.green == 12
      assert File.read!(chart) =~ "<svg"
    end
  end
end
