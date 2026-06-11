defmodule Skein.Runtime.Llm.ReplayBackend do
  @moduledoc """
  LLM backend that serves recorded responses from an active replay context.

  Selected automatically by `Skein.Runtime.Llm` when `Skein.Runtime.Replay`
  has replay state active in the calling process. Never contacts a real
  provider: every call consumes the next recorded `llm` event from the
  trace, validating that the recorded model and method match the live call.
  Divergence — a different model/method, or a trace with no responses
  left — returns a structured `provider_error` naming the problem.
  """

  @behaviour Skein.Runtime.Llm.Backend

  alias Skein.Runtime.Llm.Error
  alias Skein.Runtime.Replay

  @impl true
  def chat(model, _system, _input), do: consume(model, :chat)

  @impl true
  def json(model, _system, _input, _schema), do: consume(model, :json)

  @impl true
  def stream(model, _system, _input) do
    case consume(model, :stream) do
      {:ok, chunks} when is_list(chunks) -> {:ok, chunks}
      {:ok, text} when is_binary(text) -> {:ok, [text]}
      {:error, _} = error -> error
    end
  end

  @impl true
  def embed(model, _input), do: consume(model, :embed)

  defp consume(model, method) do
    case Replay.next_response(:llm, %{model: model, method: method}) do
      {:ok, response} ->
        {:ok, response}

      :exhausted ->
        {:error,
         Error.provider_error(
           "replay",
           "Replay trace exhausted: no recorded llm response remains for #{method} on '#{model}'"
         )}

      {:mismatch, message} ->
        {:error, Error.provider_error("replay", message)}

      :no_replay ->
        {:error, Error.provider_error("replay", "Replay context is not active in this process")}
    end
  end
end
