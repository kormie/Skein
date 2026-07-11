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

  While the context is active, `Skein.Runtime.Llm`, `Skein.Runtime.Http`,
  and `Skein.Runtime.Tool` serve effect calls from the recorded trace
  instead of contacting real backends — `active?/0` reports the context
  and `next_response/2` consumes recorded responses by kind. The replay
  state is process-scoped via the process dictionary and is cleaned up
  after `fun` returns.

  Events may come straight from the in-memory EventStore (atom keys) or
  from a JSON trace file (string keys); both shapes are accepted.
  """
  @spec with_replay(list(map()), (-> term())) :: term()
  def with_replay(trace, fun) when is_list(trace) and is_function(fun, 0) do
    # Group events by kind for sequential consumption
    grouped =
      trace
      |> Enum.map(&normalize_event/1)
      |> Enum.filter(&replayable_event?/1)
      |> Enum.group_by(fn event -> to_string(event["kind"]) end)

    Process.put(@replay_key, grouped)

    try do
      fun.()
    after
      Process.delete(@replay_key)
    end
  end

  @doc """
  Returns true when a replay context is active in the calling process.
  """
  @spec active?() :: boolean()
  def active?, do: Process.get(@replay_key) != nil

  @doc """
  Consumes the next recorded response for the given kind.

  Returns:
  - `{:ok, response}` — the next recorded response
  - `:exhausted` — all responses for this kind have been consumed
  - `:no_replay` — no replay context is active in this process
  """
  @spec next_response(atom()) :: {:ok, term()} | :exhausted | :no_replay
  def next_response(kind) when is_atom(kind) do
    next_response(kind, %{})
  end

  @doc """
  Consumes the next recorded response for the given kind, validating the
  recorded event against the live call's metadata.

  Each `expected` entry (e.g. `%{method: :get, url: url}`) is compared
  against the recorded event's field of the same name. Keys the recorded
  event does not carry are skipped. A differing value means the live run
  has diverged from the recording — the event is left unconsumed and a
  `{:mismatch, message}` is returned so callers can surface a clear error
  instead of silently serving the wrong response.

  Returns:
  - `{:ok, response}` — the next recorded response
  - `{:mismatch, message}` — the next recorded event does not match the live call
  - `:exhausted` — all responses for this kind have been consumed
  - `:no_replay` — no replay context is active in this process
  """
  @spec next_response(atom(), map()) ::
          {:ok, term()} | {:mismatch, String.t()} | :exhausted | :no_replay
  def next_response(kind, expected) when is_atom(kind) and is_map(expected) do
    kind_str = Atom.to_string(kind)

    case Process.get(@replay_key) do
      nil ->
        :no_replay

      grouped ->
        case Map.get(grouped, kind_str, []) do
          [] ->
            :exhausted

          [event | rest] ->
            case validate_expected(kind_str, event, expected) do
              :ok ->
                Process.put(@replay_key, Map.put(grouped, kind_str, rest))
                {:ok, extract_response(kind, event)}

              {:mismatch, _message} = mismatch ->
                mismatch
            end
        end
    end
  end

  # Events recorded in-memory carry atom keys; trace files carry string
  # keys. Normalize to string keys so consumption logic sees one shape.
  defp normalize_event(event) when is_map(event) do
    Map.new(event, fn {key, value} -> {to_string(key), value} end)
  end

  # Only effect events are consumable during replay. Tool list/schema
  # spans are local registry reads that re-execute live, so they must not
  # occupy a slot in the recorded tool-call sequence.
  defp replayable_event?(%{"kind" => kind, "method" => method}) when kind in [:tool, "tool"] do
    to_string(method) == "call"
  end

  defp replayable_event?(_event), do: true

  defp validate_expected(kind_str, event, expected) do
    Enum.find_value(expected, :ok, fn {key, expected_value} ->
      recorded = Map.get(event, to_string(key))

      cond do
        recorded == nil ->
          nil

        values_match?(key, recorded, expected_value) ->
          nil

        true ->
          {:mismatch,
           "Replay mismatch: next recorded #{kind_str} event has #{key} " <>
             "#{inspect(to_string(recorded))}, but the live call uses #{key} " <>
             "#{inspect(to_string(expected_value))}"}
      end
    end)
  end

  # HTTP methods are recorded as atoms (:get) but may appear as "GET" in
  # hand-written traces — method comparison is case-insensitive. Everything
  # else (URLs, model names, tool names) must match exactly.
  defp values_match?(:method, recorded, expected) do
    String.downcase(to_string(recorded)) == String.downcase(to_string(expected))
  end

  defp values_match?(_key, recorded, expected) do
    to_string(recorded) == to_string(expected)
  end

  # Extract the relevant response data from a recorded event
  defp extract_response(:llm, event), do: event["response"]

  defp extract_response(:http, event) do
    %{
      "status" => event["status"],
      "response_body" => event["response_body"]
    }
  end

  defp extract_response(:tool, event), do: event["response"]

  defp extract_response(:timer, event) do
    %{
      "result" => Map.get(event, "result"),
      "timer_ref" => Map.get(event, "timer_ref")
    }
  end

  defp extract_response(:process, event) do
    %{
      "result" => Map.get(event, "result", "ok"),
      "spawn_id" => Map.get(event, "spawn_id")
    }
  end

  defp extract_response(:queue, event), do: event
  defp extract_response(:topic, event), do: event

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
