defmodule Skein.Runtime.Llm.EventStream do
  @moduledoc """
  Codec for AWS's binary event-stream framing
  (`application/vnd.amazon.eventstream`), used by Bedrock's
  `converse-stream` endpoint instead of SSE.

  Each message on the wire is:

      <<total_length::32, headers_length::32, prelude_crc::32,   # prelude
        headers::binary-size(headers_length),
        payload::binary,
        message_crc::32>>

  `prelude_crc` is the CRC32 of the first 8 bytes; `message_crc` is the
  CRC32 of everything before it. Headers are length-prefixed
  name/typed-value pairs — Bedrock events carry string headers
  (`:message-type`, `:event-type` / `:exception-type`, `:content-type`)
  and a JSON payload.

  `parse_frames/1` is a pure incremental parser: feed it any
  concatenation of network chunks and it returns the complete messages
  plus the unconsumed remainder to prepend to the next chunk. CRC or
  structural corruption is a terminal `{:error, reason}`.
  """

  @typedoc """
  A decoded event-stream message.

  Header values decode by wire type: strings and booleans as
  themselves, the integer types as integers, and the binary-ish types
  tagged (`{:bytes, binary}`, `{:timestamp, millis}`, `{:uuid,
  <<_::128>>}`) so they can't be confused with strings.
  """
  @type message :: %{headers: %{String.t() => header_value()}, payload: binary()}

  @type header_value ::
          boolean()
          | integer()
          | String.t()
          | {:bytes, binary()}
          | {:timestamp, integer()}
          | {:uuid, <<_::128>>}

  # prelude (8) + prelude CRC (4) + message CRC (4)
  @envelope_bytes 16

  @doc """
  Parses every complete message out of `buffer`.

  Returns `{:ok, messages, rest}` where `rest` is the trailing bytes of
  a not-yet-complete message (prepend it to the next network chunk), or
  `{:error, reason}` on CRC mismatch or malformed framing — corruption
  is not recoverable mid-stream.
  """
  @spec parse_frames(binary()) :: {:ok, [message()], binary()} | {:error, term()}
  def parse_frames(buffer) when is_binary(buffer), do: parse_frames(buffer, [])

  defp parse_frames(buffer, acc) when byte_size(buffer) < 12 do
    {:ok, Enum.reverse(acc), buffer}
  end

  defp parse_frames(buffer, acc) do
    <<prelude::binary-size(8), prelude_crc::32, _::binary>> = buffer
    <<total_length::32, headers_length::32>> = prelude

    cond do
      :erlang.crc32(prelude) != prelude_crc ->
        {:error, :prelude_crc_mismatch}

      total_length < @envelope_bytes or headers_length > total_length - @envelope_bytes ->
        {:error, {:invalid_prelude, total_length, headers_length}}

      byte_size(buffer) < total_length ->
        {:ok, Enum.reverse(acc), buffer}

      true ->
        <<message::binary-size(total_length), rest::binary>> = buffer
        body_size = total_length - 4
        <<body::binary-size(body_size), message_crc::32>> = message

        with :ok <- check_message_crc(body, message_crc),
             {:ok, headers, payload} <- split_message(body, headers_length) do
          parse_frames(rest, [%{headers: headers, payload: payload} | acc])
        end
    end
  end

  defp check_message_crc(body, message_crc) do
    if :erlang.crc32(body) == message_crc, do: :ok, else: {:error, :message_crc_mismatch}
  end

  defp split_message(body, headers_length) do
    <<_prelude::binary-size(12), headers_bin::binary-size(headers_length), payload::binary>> =
      body

    with {:ok, headers} <- parse_headers(headers_bin, %{}) do
      {:ok, headers, payload}
    end
  end

  defp parse_headers(<<>>, acc), do: {:ok, acc}

  defp parse_headers(<<name_len::8, name::binary-size(name_len), type::8, rest::binary>>, acc)
       when name_len > 0 do
    case parse_header_value(type, rest) do
      {:ok, value, rest} -> parse_headers(rest, Map.put(acc, name, value))
      :error -> {:error, :malformed_headers}
    end
  end

  defp parse_headers(_other, _acc), do: {:error, :malformed_headers}

  defp parse_header_value(0, rest), do: {:ok, true, rest}
  defp parse_header_value(1, rest), do: {:ok, false, rest}
  defp parse_header_value(2, <<v::signed-8, rest::binary>>), do: {:ok, v, rest}
  defp parse_header_value(3, <<v::signed-16, rest::binary>>), do: {:ok, v, rest}
  defp parse_header_value(4, <<v::signed-32, rest::binary>>), do: {:ok, v, rest}
  defp parse_header_value(5, <<v::signed-64, rest::binary>>), do: {:ok, v, rest}

  defp parse_header_value(6, <<len::16, v::binary-size(len), rest::binary>>),
    do: {:ok, {:bytes, v}, rest}

  defp parse_header_value(7, <<len::16, v::binary-size(len), rest::binary>>),
    do: {:ok, v, rest}

  defp parse_header_value(8, <<v::signed-64, rest::binary>>), do: {:ok, {:timestamp, v}, rest}

  defp parse_header_value(9, <<v::binary-size(16), rest::binary>>), do: {:ok, {:uuid, v}, rest}

  defp parse_header_value(_type, _rest), do: :error

  @doc """
  Encodes one event-stream message — the inverse of `parse_frames/1`.

  Integer header values encode as the 64-bit type, so values (not wire
  bytes) round-trip. Used by tests and stub servers; Skein never sends
  event-stream frames to AWS.
  """
  @spec encode_message(%{String.t() => header_value()} | [{String.t(), header_value()}], binary()) ::
          binary()
  def encode_message(headers, payload) when is_binary(payload) do
    headers_bin = headers |> Enum.map(&encode_header/1) |> IO.iodata_to_binary()
    total_length = @envelope_bytes + byte_size(headers_bin) + byte_size(payload)
    prelude = <<total_length::32, byte_size(headers_bin)::32>>

    body =
      IO.iodata_to_binary([prelude, <<:erlang.crc32(prelude)::32>>, headers_bin, payload])

    body <> <<:erlang.crc32(body)::32>>
  end

  defp encode_header({name, value}) when byte_size(name) in 1..255 do
    [<<byte_size(name)::8>>, name, encode_header_value(value)]
  end

  defp encode_header_value(true), do: <<0>>
  defp encode_header_value(false), do: <<1>>
  defp encode_header_value(v) when is_integer(v), do: <<5, v::signed-64>>

  defp encode_header_value(v) when is_binary(v) and byte_size(v) <= 0xFFFF,
    do: <<7, byte_size(v)::16, v::binary>>

  defp encode_header_value({:bytes, v}) when byte_size(v) <= 0xFFFF,
    do: <<6, byte_size(v)::16, v::binary>>

  defp encode_header_value({:timestamp, v}) when is_integer(v), do: <<8, v::signed-64>>

  defp encode_header_value({:uuid, v}) when byte_size(v) == 16, do: <<9, v::binary>>
end
