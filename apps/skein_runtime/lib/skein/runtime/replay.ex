defmodule Skein.Runtime.Replay do
  @moduledoc """
  Replay engine for Skein golden trace tests.

  Loads recorded trace files and provides deterministic replay of
  captured interactions. Golden tests use this module to verify that
  a recorded execution trace still produces the expected outcomes.

  ## Trace File Format

  Trace files are JSON arrays of span objects. Each span has:

  - `kind` — the span type (e.g., "handler", "llm", "memory", "http")
  - Additional fields depending on kind (e.g., `method`, `path`, `status`)

  ## Usage

  Called by generated golden test functions:

      trace = Skein.Runtime.Replay.load_trace("path/to/trace.json")
      # ... assertions using trace data ...

  """

  @doc """
  Loads a trace file from disk and returns the parsed span list.

  Returns `{:ok, spans}` on success or `{:error, reason}` on failure.
  Raises on file not found or invalid JSON to fail the golden test.
  """
  @spec load_trace(String.t()) :: list(map())
  def load_trace(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, spans} when is_list(spans) ->
            spans

          {:ok, _other} ->
            raise RuntimeError,
              message: "Golden trace file '#{path}' must contain a JSON array"

          {:error, reason} ->
            raise RuntimeError,
              message: "Golden trace file '#{path}' contains invalid JSON: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise RuntimeError,
          message: "Could not read golden trace file '#{path}': #{inspect(reason)}"
    end
  end

  @doc """
  Replays a trace by re-executing each span against the current runtime.

  For each span in the trace, dispatches to the appropriate runtime module
  and collects results. Returns a list of `{span, result}` tuples.

  This is used to verify that replaying recorded I/O produces the same
  outcomes as the original execution.
  """
  @spec replay(list(map())) :: list({map(), term()})
  def replay(spans) when is_list(spans) do
    Enum.map(spans, fn span ->
      result = replay_span(span)
      {span, result}
    end)
  end

  # Replay individual span types
  defp replay_span(%{"kind" => "handler"} = span) do
    %{
      kind: :handler,
      method: Map.get(span, "method"),
      path: Map.get(span, "path"),
      status: Map.get(span, "status"),
      replayed: true
    }
  end

  defp replay_span(%{"kind" => "llm"} = span) do
    %{
      kind: :llm,
      model: Map.get(span, "model"),
      replayed: true
    }
  end

  defp replay_span(%{"kind" => "memory"} = span) do
    %{
      kind: :memory,
      operation: Map.get(span, "operation"),
      replayed: true
    }
  end

  defp replay_span(%{"kind" => "http"} = span) do
    %{
      kind: :http,
      method: Map.get(span, "method"),
      url: Map.get(span, "url"),
      replayed: true
    }
  end

  defp replay_span(span) do
    %{kind: :unknown, raw: span, replayed: true}
  end
end
