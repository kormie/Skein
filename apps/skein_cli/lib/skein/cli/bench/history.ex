defmodule Skein.CLI.Bench.History do
  @moduledoc """
  Append-only history of live agent-writability benchmark runs (#320),
  plus the SVG trend chart rendered from it.

  Every live run appends one JSON line to
  `conformance/writability/history.jsonl` and regenerates the chart at
  `docs/site/public/writability-history.svg`, so the README and the docs
  site show the measured writability trend — first-try compile rate and
  tasks-green rate over recorded runs. Both land in the same PR as the
  refreshed recordings; nothing regenerates outside a live run.
  """

  @type entry :: %{
          recorded_at: String.t(),
          model: String.t() | nil,
          tasks: non_neg_integer(),
          green: non_neg_integer(),
          first_try: non_neg_integer(),
          mean_iterations_to_green: number() | nil
        }

  # Chart geometry and the validated light-surface palette (series colors
  # pass the CVD/lightness/chroma checks; the aqua contrast warning is
  # relieved by direct labels and the jsonl acting as the table view).
  @width 640
  @height 260
  @margin %{top: 44, right: 150, bottom: 34, left: 44}
  @surface "#fcfcfb"
  @grid "#e5e4df"
  @ink "#262521"
  @ink_soft "#6f6e66"
  @series_green "#2a78d6"
  @series_first_try "#1baf7a"

  @doc "Appends one benchmark report to the history file."
  @spec append(Path.t(), map(), String.t()) :: :ok | {:error, String.t()}
  def append(path, report, recorded_at) do
    summary = report.summary

    line =
      Jason.encode!(%{
        "recorded_at" => recorded_at,
        "model" => report.model,
        "tasks" => summary.tasks,
        "green" => summary.green,
        "first_try" => summary.first_try,
        "mean_iterations_to_green" => summary.mean_iterations_to_green
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, line <> "\n", [:append]) do
      :ok
    else
      {:error, reason} -> {:error, "could not append history at #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Loads history entries in file (chronological) order.

  A missing file is an empty history, not an error.
  """
  @spec load(Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "could not read history at #{path}: #{inspect(reason)}"}

      {:ok, raw} ->
        entries =
          raw
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            decoded = Jason.decode!(line)

            %{
              recorded_at: decoded["recorded_at"],
              model: decoded["model"],
              tasks: decoded["tasks"],
              green: decoded["green"],
              first_try: decoded["first_try"],
              mean_iterations_to_green: decoded["mean_iterations_to_green"]
            }
          end)

        {:ok, entries}
    end
  end

  @doc """
  Appends the run to the history and regenerates the chart.

  Options: `:history_path`, `:chart_path`, `:recorded_at` (all required).
  """
  @spec record(map(), keyword()) :: :ok | {:error, String.t()}
  def record(report, opts) do
    history_path = Keyword.fetch!(opts, :history_path)
    chart_path = Keyword.fetch!(opts, :chart_path)
    recorded_at = Keyword.fetch!(opts, :recorded_at)

    with :ok <- append(history_path, report, recorded_at),
         {:ok, entries} <- load(history_path),
         :ok <- File.mkdir_p(Path.dirname(chart_path)),
         :ok <- File.write(chart_path, render_svg(entries)) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "could not write chart at #{chart_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Renders the history as a static SVG line chart.

  One percentage axis (0–100%), two series: tasks-green rate and
  first-try compile rate. Direct end labels and a legend carry identity
  in ink; each marker has a native `<title>` tooltip.
  """
  @spec render_svg([entry()]) :: String.t()
  def render_svg(entries) do
    plot_width = @width - @margin.left - @margin.right
    plot_height = @height - @margin.top - @margin.bottom

    x = fn index ->
      case length(entries) do
        1 -> @margin.left + plot_width / 2
        n -> @margin.left + index * plot_width / (n - 1)
      end
    end

    y = fn percent -> @margin.top + (100 - percent) / 100 * plot_height end

    series = [
      {"tasks green", @series_green, fn e -> percent(e.green, e.tasks) end},
      {"first-try compile", @series_first_try, fn e -> percent(e.first_try, e.tasks) end}
    ]

    gridlines =
      Enum.map_join([0, 25, 50, 75, 100], "\n", fn percent ->
        line_y = y.(percent)

        ~s(<line x1="#{@margin.left}" y1="#{fmt(line_y)}" x2="#{@margin.left + plot_width}" y2="#{fmt(line_y)}" stroke="#{@grid}" stroke-width="1"/>) <>
          ~s(<text x="#{@margin.left - 8}" y="#{fmt(line_y + 4)}" text-anchor="end" font-size="11" fill="#{@ink_soft}">#{percent}%</text>)
      end)

    x_labels =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {_, index} -> show_x_label?(index, length(entries)) end)
      |> Enum.map_join("\n", fn {entry, index} ->
        ~s(<text x="#{fmt(x.(index))}" y="#{@height - 12}" text-anchor="middle" font-size="11" fill="#{@ink_soft}">#{date_label(entry.recorded_at)}</text>)
      end)

    series_svg =
      Enum.map_join(series, "\n", fn {name, color, value} ->
        points =
          entries
          |> Enum.with_index()
          |> Enum.map(fn {entry, index} ->
            {x.(index), y.(value.(entry)), entry, value.(entry)}
          end)

        polyline =
          ~s(<polyline fill="none" stroke="#{color}" stroke-width="2" points="#{Enum.map_join(points, " ", fn {px, py, _, _} -> "#{fmt(px)},#{fmt(py)}" end)}"/>)

        markers =
          Enum.map_join(points, "\n", fn {px, py, entry, val} ->
            ~s(<circle cx="#{fmt(px)}" cy="#{fmt(py)}" r="4" fill="#{color}" stroke="#{@surface}" stroke-width="2">) <>
              ~s(<title>#{date_label(entry.recorded_at)} — #{name}: #{fmt_percent(val)} \(#{entry.model}\)</title></circle>)
          end)

        {last_x, last_y, _, last_val} = List.last(points)

        end_label =
          ~s(<text x="#{fmt(last_x + 10)}" y="#{fmt(last_y + 4)}" font-size="12" fill="#{@ink}">#{name} #{fmt_percent(last_val)}</text>)

        polyline <> "\n" <> markers <> "\n" <> end_label
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}" role="img" aria-label="Agent-writability benchmark: tasks-green and first-try compile rates over recorded live runs">
    <rect width="#{@width}" height="#{@height}" fill="#{@surface}"/>
    <text x="#{@margin.left}" y="22" font-size="14" font-weight="600" fill="#{@ink}" font-family="system-ui, sans-serif">Agent writability — live benchmark runs</text>
    <g font-family="system-ui, sans-serif">
    #{gridlines}
    #{x_labels}
    #{series_svg}
    </g>
    </svg>
    """
  end

  defp percent(_part, 0), do: 0.0
  defp percent(part, whole), do: part / whole * 100

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp fmt(value), do: to_string(value)

  defp fmt_percent(value), do: "#{round(value)}%"

  defp date_label(recorded_at) when is_binary(recorded_at) do
    String.slice(recorded_at, 0, 10)
  end

  defp date_label(_), do: "?"

  # With many runs, label the first, the last, and every k-th in between.
  defp show_x_label?(_index, count) when count <= 6, do: true

  defp show_x_label?(index, count) do
    step = div(count - 1, 5) + 1
    index == count - 1 or rem(index, step) == 0
  end
end
