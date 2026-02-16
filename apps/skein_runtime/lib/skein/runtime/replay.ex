defmodule Skein.Runtime.Replay do
  @moduledoc """
  Replay engine for Skein golden trace tests.

  Loads recorded event streams and provides deterministic replay of
  captured interactions. Golden tests use this module to verify that
  a recorded execution trace still produces the expected outcomes.

  ## Event File Format

  Event files are JSON arrays of event objects from the unified EventStore.
  Each event has at minimum:

  - `kind` — the event type (e.g., "effect", "state_change", "user_event",
    "annotation", or legacy kinds like "handler", "llm", "memory", "http")
  - Additional fields depending on kind

  ## Usage

  Called by generated golden test functions:

      events = Skein.Runtime.Replay.load_trace("path/to/trace.json")
      # ... assertions using event data ...

  ## Memory Reconstruction

  The replay engine can reconstruct memory state from `:state_change` events:

      state = Skein.Runtime.Replay.rebuild_memory(events, "sessions")
      # => %{"user_id" => "u-123", "decision" => "approved"}

  """

  @doc """
  Loads a trace file from disk and returns the parsed event list.

  Returns the list of events on success.
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
  Replays a trace by re-executing each event against the current runtime.

  For each event in the trace, dispatches to the appropriate runtime module
  and collects results. Returns a list of `{event, result}` tuples.

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

  @doc """
  Reconstructs memory state for a namespace from a list of events.

  Filters for `state_change` events matching the given namespace, then
  replays puts and deletes in order to produce the final state.

  Returns a map of `%{key => value}`.
  """
  @spec rebuild_memory(list(map()), String.t()) :: %{String.t() => any()}
  def rebuild_memory(events, namespace) when is_list(events) and is_binary(namespace) do
    events
    |> Enum.filter(fn event ->
      (event["kind"] == "state_change" or Map.get(event, :kind) == :state_change) and
        (event["namespace"] == namespace or Map.get(event, :namespace) == namespace)
    end)
    |> Enum.reduce(%{}, fn event, acc ->
      operation = event["operation"] || event[:operation]
      key = event["key"] || event[:key]

      case to_string(operation) do
        "put" ->
          value = event["value"] || event[:value]
          Map.put(acc, key, value)

        "delete" ->
          Map.delete(acc, key)
      end
    end)
  end

  # Replay individual span types
  # ------------------------------------------------------------------
  # Recorded response injection
  # ------------------------------------------------------------------

  @replay_key :skein_replay_state

  @doc """
  Executes `fun` with a replay context loaded from the given trace.

  During execution, `next_response/1` can be called to consume recorded
  responses by kind. The replay state is process-scoped via the process
  dictionary and is cleaned up after `fun` returns.
  """
  @spec with_replay(list(map()), (-> term())) :: term()
  def with_replay(trace, fun) when is_list(trace) and is_function(fun, 0) do
    # Group events by kind for sequential consumption
    grouped =
      trace
      |> Enum.group_by(fn event -> event["kind"] end)
      |> Enum.into(%{}, fn {kind, events} -> {kind, events} end)

    Process.put(@replay_key, grouped)

    try do
      fun.()
    after
      Process.delete(@replay_key)
    end
  end

  @doc """
  Consumes the next recorded response for the given kind.

  Returns:
  - `{:ok, response}` — the next recorded response
  - `:exhausted` — all responses for this kind have been consumed
  - `:no_replay` — no replay context is active in this process
  """
  @spec next_response(atom()) :: {:ok, term()} | :exhausted | :no_replay
  def next_response(kind) when is_atom(kind) do
    kind_str = Atom.to_string(kind)

    case Process.get(@replay_key) do
      nil ->
        :no_replay

      grouped ->
        case Map.get(grouped, kind_str, []) do
          [] ->
            :exhausted

          [event | rest] ->
            Process.put(@replay_key, Map.put(grouped, kind_str, rest))
            {:ok, extract_response(kind, event)}
        end
    end
  end

  # Extract the relevant response data from a recorded event
  defp extract_response(:llm, event), do: event["response"]

  defp extract_response(:http, event) do
    %{
      "status" => event["status"],
      "response_body" => event["response_body"]
    }
  end

  defp extract_response(_kind, event), do: event

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

  defp replay_span(%{"kind" => "state_change"} = span) do
    %{
      kind: :state_change,
      namespace: Map.get(span, "namespace"),
      operation: Map.get(span, "operation"),
      key: Map.get(span, "key"),
      value: Map.get(span, "value"),
      replayed: true
    }
  end

  defp replay_span(%{"kind" => "user_event"} = span) do
    %{
      kind: :user_event,
      event: Map.get(span, "event"),
      data: Map.get(span, "data"),
      replayed: true
    }
  end

  defp replay_span(%{"kind" => "annotation"} = span) do
    %{
      kind: :annotation,
      key: Map.get(span, "key"),
      value: Map.get(span, "value"),
      replayed: true
    }
  end

  defp replay_span(span) do
    %{kind: :unknown, raw: span, replayed: true}
  end
end
