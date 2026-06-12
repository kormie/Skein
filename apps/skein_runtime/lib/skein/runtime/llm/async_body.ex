defmodule Skein.Runtime.Llm.AsyncBody do
  @moduledoc """
  Receive-loop helpers for Req's `into: :self` streaming responses.

  With `into: :self`, `response.body` is a `Req.Response.Async` and the
  body arrives as raw process messages keyed by the async's *ref* —
  matching on anything else (like the struct itself) receives nothing
  and hangs until timeout. `collect/4` is the one correct loop both
  streaming backends fold over: it classifies messages through the
  adapter's `stream_fun` (so it works under Finch and the plug test
  adapter alike) and enforces an inactivity timeout. `drain/2` slurps
  the rest of the body, which error handling needs when a streaming
  request answers non-200.
  """

  @doc """
  Folds `fun` over the data chunks of an async response body.

  `fun` receives each binary chunk and the accumulator, returning
  `{:cont, acc}` to keep reading or `{:halt, result}` to cancel the
  request and stop early.

  Returns `{:done, acc}` when the stream ends, `{:halted, result}`
  after a halt, `{:stream_error, reason}` if the transport fails
  mid-stream, or `:timeout` (request cancelled) after `timeout_ms`
  without a message.
  """
  @spec collect(
          Req.Response.Async.t(),
          acc,
          non_neg_integer(),
          (binary(), acc -> {:cont, acc} | {:halt, term()})
        ) :: {:done, acc} | {:halted, term()} | {:stream_error, term()} | :timeout
        when acc: var
  def collect(%Req.Response.Async{ref: ref} = async, acc, timeout_ms, fun) do
    receive do
      {^ref, _} = message ->
        case async.stream_fun.(ref, message) do
          {:ok, entries} -> handle_entries(entries, async, acc, timeout_ms, fun)
          {:error, reason} -> {:stream_error, reason}
        end
    after
      timeout_ms ->
        cancel(async)
        :timeout
    end
  end

  defp handle_entries([], async, acc, timeout_ms, fun) do
    collect(async, acc, timeout_ms, fun)
  end

  defp handle_entries([{:data, data} | rest], async, acc, timeout_ms, fun) do
    case fun.(data, acc) do
      {:cont, acc} ->
        handle_entries(rest, async, acc, timeout_ms, fun)

      {:halt, result} ->
        cancel(async)
        {:halted, result}
    end
  end

  defp handle_entries([:done | _rest], _async, acc, _timeout_ms, _fun), do: {:done, acc}

  defp handle_entries([{:trailers, _trailers} | rest], async, acc, timeout_ms, fun) do
    handle_entries(rest, async, acc, timeout_ms, fun)
  end

  @doc """
  Reads the remaining body of an async response into one binary.

  Best-effort: anything other than a clean end of stream (transport
  error, timeout) returns `""`.
  """
  @spec drain(Req.Response.Async.t(), non_neg_integer()) :: binary()
  def drain(%Req.Response.Async{} = async, timeout_ms) do
    case collect(async, [], timeout_ms, fn data, acc -> {:cont, [acc, data]} end) do
      {:done, parts} -> IO.iodata_to_binary(parts)
      _other -> ""
    end
  end

  defp cancel(%Req.Response.Async{} = async) do
    async.cancel_fun.(async.ref)
  catch
    _kind, _reason -> :ok
  end
end
