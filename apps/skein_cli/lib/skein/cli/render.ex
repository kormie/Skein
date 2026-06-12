defmodule Skein.CLI.Render do
  @moduledoc """
  Plain-text rendering of CLI command results.

  This is the single source of truth for the line-oriented output of
  `skein trace` (and the data the TUI renders interactively). Keeping it
  pure makes the plain output testable byte-for-byte and guarantees the
  non-TTY / `--no-tui` path stays stable as interactive surfaces evolve.

  Output is ASCII-only: it must print correctly on latin1 stdout.
  """

  @doc """
  Renders a `Skein.CLI.trace/1` result as the plain trace listing.

  Handles every event kind the EventStore can return (effect spans,
  annotations, user events, state changes) and never raises on spans
  with missing fields.
  """
  @spec trace_plain(%{spans: [map()], count: non_neg_integer()}) :: String.t()
  def trace_plain(%{spans: spans, count: count}) do
    Enum.join(["Traces (#{count}):" | Enum.map(spans, &("  " <> span_line(&1)))], "\n")
  end

  @doc """
  Renders one span as a single ASCII line (without indentation).

  Shared by the plain listing and the interactive TUI so both surfaces
  describe spans identically.
  """
  @spec span_line(map()) :: String.t()
  def span_line(span) do
    kind = Map.get(span, :kind, :span)

    parts =
      [kind_summary(kind, span), duration_part(span), error_part(span)]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    Enum.join(["[#{kind}]" | parts], " ")
  end

  defp kind_summary(:annotation, span) do
    case {Map.get(span, :key), Map.get(span, :value)} do
      {nil, _} -> []
      {key, value} -> ["#{key}=#{value}"]
    end
  end

  defp kind_summary(:user_event, span) do
    event = Map.get(span, :event)
    agent = Map.get(span, :agent)
    phase = Map.get(span, :phase)

    [
      if(event, do: "#{event}"),
      if(agent, do: "agent=#{agent}"),
      if(phase, do: "phase=#{phase}")
    ]
  end

  defp kind_summary(:state_change, span) do
    operation = Map.get(span, :operation)
    namespace = Map.get(span, :namespace)
    key = Map.get(span, :key)

    [
      if(operation, do: "#{operation}"),
      if(namespace || key, do: "#{namespace}/#{key}")
    ]
  end

  defp kind_summary(_kind, span) do
    method = Map.get(span, :method)
    url = Map.get(span, :url)
    status = Map.get(span, :status)

    [
      if(method, do: "#{method}"),
      if(url, do: "#{url}"),
      if(status, do: "-> #{status}")
    ]
  end

  defp duration_part(%{duration_us: us}) when is_integer(us) do
    "(#{Float.round(us / 1000, 1)}ms)"
  end

  defp duration_part(_span), do: nil

  defp error_part(%{outcome: :error} = span) do
    case Map.get(span, :error) do
      nil -> "error"
      message -> "error: #{message}"
    end
  end

  defp error_part(_span), do: nil
end
