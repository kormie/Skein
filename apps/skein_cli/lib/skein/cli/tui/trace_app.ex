defmodule Skein.CLI.Tui.TraceApp do
  @moduledoc """
  Interactive trace explorer — the first TUI surface for issue #171.

  A TEA application over an already-fetched `Skein.CLI.trace/1` result.
  The model and its transitions are plain data with no framework types,
  so the application logic ports to any TEA framework; only `view/1`
  speaks Raxol. Span lines reuse `Skein.CLI.Render.span_line/1`, the
  same renderer that produces the plain output.

  Keys: j/k or arrow keys move the selection, q or Ctrl-C quits.
  """

  use Raxol.Core.Runtime.Application

  @impl true
  def init(%{options: options}) do
    options
    |> Keyword.get(:trace_result, %{spans: [], count: 0})
    |> new_model()
  end

  @doc """
  Builds the initial model from a `Skein.CLI.trace/1` result.
  """
  @spec new_model(%{spans: [map()], count: non_neg_integer()}) :: map()
  def new_model(%{spans: spans, count: count}) do
    %{spans: spans, count: count, selected: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("q") -> {model, [command(:quit)]}
      key_match("c", ctrl: true) -> {model, [command(:quit)]}
      key_match(:down) -> {select(model, 1), []}
      key_match("j") -> {select(model, 1), []}
      key_match(:up) -> {select(model, -1), []}
      key_match("k") -> {select(model, -1), []}
      _ -> {model, []}
    end
  end

  @doc """
  Moves the selection by `step`, clamped to the span list bounds.
  """
  @spec select(map(), integer()) :: map()
  def select(%{spans: []} = model, _step), do: model

  def select(model, step) do
    last = length(model.spans) - 1
    selected = model.selected |> Kernel.+(step) |> max(0) |> min(last)
    %{model | selected: selected}
  end

  @impl true
  def view(model) do
    column style: %{padding: 0, gap: 0} do
      [
        box style: %{border: :single, width: :fill} do
          column style: %{gap: 0} do
            [header(model) | span_rows(model)]
          end
        end,
        text("j/k or arrows: move   q: quit", style: [:dim])
      ]
    end
  end

  defp header(model) do
    text("Traces (#{model.count})", style: [:bold], fg: :cyan)
  end

  defp span_rows(%{spans: []}) do
    [text("(no spans recorded)", style: [:dim])]
  end

  defp span_rows(model) do
    model.spans
    |> Enum.with_index()
    |> Enum.map(fn {span, index} ->
      line = Skein.CLI.Render.span_line(span)

      if index == model.selected do
        text("> " <> line, style: [:bold], fg: :yellow)
      else
        text("  " <> line)
      end
    end)
  end
end
