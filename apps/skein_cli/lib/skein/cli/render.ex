defmodule Skein.CLI.Render do
  @moduledoc """
  Pure, framework-neutral rendering of CLI output (#284).

  All functions are total over the span/result shapes the runtime produces, take
  plain data and return a `String.t()` — no IO, no TTY, no TUI. Output is
  ASCII-only and byte-stable so it can be pinned by golden tests and piped
  deterministically. The `skein trace` command and any future TTY/TUI front-end
  both render through this module; non-TTY/MCP/LSP output never routes through a
  TUI.
  """

  @doc """
  Renders a trace result (`%{spans: [span], count: n}`) to plain text.

  Each span is a map carrying any of `:kind`, `:method`, `:url`, `:status`,
  `:outcome`, and `:duration_us` (string or atom keys both accepted). Missing
  fields are simply omitted, so every EventStore kind renders without crashing.
  The output ends with a trailing newline.
  """
  @spec trace(%{spans: [map()], count: non_neg_integer()}) :: String.t()
  def trace(%{spans: spans, count: count}) do
    header = "Traces (#{count}):"
    lines = Enum.map(spans, &trace_line/1)
    Enum.join([header | lines], "\n") <> "\n"
  end

  defp trace_line(span) do
    parts =
      [
        bracket(field(span, :kind)),
        to_text(field(span, :method)),
        to_text(field(span, :url)),
        status_arrow(field(span, :status)),
        to_text(field(span, :outcome)),
        duration(field(span, :duration_us))
      ]
      |> Enum.reject(&(&1 == nil))

    "  " <> Enum.join(parts, " ")
  end

  defp bracket(nil), do: "[?]"
  defp bracket(value), do: "[#{to_text(value)}]"

  defp status_arrow(nil), do: nil
  defp status_arrow(status), do: "-> #{to_text(status)}"

  defp duration(nil), do: nil

  defp duration(us) when is_integer(us) or is_float(us) do
    ms = Float.round(us / 1000, 1)
    "(#{:erlang.float_to_binary(ms, decimals: 1)}ms)"
  end

  defp duration(_), do: nil

  # Span maps may use atom or string keys depending on origin (live vs replayed
  # from JSON); accept both.
  defp field(span, key) when is_map(span) do
    case Map.get(span, key) do
      nil -> Map.get(span, Atom.to_string(key))
      value -> value
    end
  end

  defp to_text(nil), do: nil
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp to_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_text(value), do: inspect(value)
end
