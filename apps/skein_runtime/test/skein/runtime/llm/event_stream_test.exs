defmodule Skein.Runtime.Llm.EventStreamTest do
  @moduledoc """
  Tests for the AWS event-stream binary codec (issue #178): byte
  fixtures, frames split across transport-chunk boundaries, and CRC
  corruption.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Runtime.Llm.EventStream

  defp event_headers(event_type) do
    %{
      ":message-type" => "event",
      ":event-type" => event_type,
      ":content-type" => "application/json"
    }
  end

  describe "parse_frames/1" do
    test "round-trips a single message" do
      headers = event_headers("contentBlockDelta")
      payload = ~s({"delta":{"text":"Hello"},"contentBlockIndex":0})
      frame = EventStream.encode_message(headers, payload)

      assert {:ok, [%{headers: ^headers, payload: ^payload}], <<>>} =
               EventStream.parse_frames(frame)
    end

    test "parses a realistic Bedrock converse-stream sequence" do
      frames = [
        EventStream.encode_message(event_headers("messageStart"), ~s({"role":"assistant"})),
        EventStream.encode_message(
          event_headers("contentBlockDelta"),
          ~s({"delta":{"text":"Hel"},"contentBlockIndex":0})
        ),
        EventStream.encode_message(
          event_headers("contentBlockDelta"),
          ~s({"delta":{"text":"lo"},"contentBlockIndex":0})
        ),
        EventStream.encode_message(
          event_headers("contentBlockStop"),
          ~s({"contentBlockIndex":0})
        ),
        EventStream.encode_message(event_headers("messageStop"), ~s({"stopReason":"end_turn"})),
        EventStream.encode_message(
          event_headers("metadata"),
          ~s({"usage":{"inputTokens":5,"outputTokens":7}})
        )
      ]

      assert {:ok, messages, <<>>} = frames |> IO.iodata_to_binary() |> EventStream.parse_frames()

      assert Enum.map(messages, & &1.headers[":event-type"]) == [
               "messageStart",
               "contentBlockDelta",
               "contentBlockDelta",
               "contentBlockStop",
               "messageStop",
               "metadata"
             ]

      assert Jason.decode!(Enum.at(messages, 1).payload)["delta"]["text"] == "Hel"
    end

    test "keeps an incomplete frame as the remainder" do
      frame = EventStream.encode_message(event_headers("messageStart"), "{}")
      {complete, partial} = String.split_at(frame, byte_size(frame) - 5)

      assert {:ok, [], ^complete} = EventStream.parse_frames(complete)

      full = complete <> partial
      assert {:ok, [%{payload: "{}"}], <<>>} = EventStream.parse_frames(full)
    end

    test "a buffer shorter than the prelude is all remainder" do
      assert {:ok, [], <<1, 2, 3>>} = EventStream.parse_frames(<<1, 2, 3>>)
      assert {:ok, [], <<>>} = EventStream.parse_frames(<<>>)
    end

    test "a corrupted prelude CRC is a terminal error" do
      <<total::32, headers_len::32, crc::32, rest::binary>> =
        EventStream.encode_message(event_headers("messageStart"), "{}")

      corrupted = <<total::32, headers_len::32, crc + 1::32, rest::binary>>
      assert {:error, :prelude_crc_mismatch} = EventStream.parse_frames(corrupted)
    end

    test "a corrupted message CRC is a terminal error" do
      frame = EventStream.encode_message(event_headers("messageStart"), "{}")
      body_size = byte_size(frame) - 4
      <<body::binary-size(body_size), crc::32>> = frame

      corrupted = <<body::binary, crc + 1::32>>
      assert {:error, :message_crc_mismatch} = EventStream.parse_frames(corrupted)
    end

    test "a flipped payload byte fails the message CRC" do
      frame = EventStream.encode_message(event_headers("messageStart"), ~s({"role":"assistant"}))
      flip_at = byte_size(frame) - 8
      <<prefix::binary-size(flip_at), byte, suffix::binary>> = frame

      corrupted = <<prefix::binary, Bitwise.bxor(byte, 0xFF), suffix::binary>>
      assert {:error, :message_crc_mismatch} = EventStream.parse_frames(corrupted)
    end

    test "an inconsistent prelude length is a structural error" do
      # total_length shorter than the 16-byte envelope, with a valid
      # prelude CRC so the structural check is what fires.
      prelude = <<8::32, 0::32>>
      bogus = prelude <> <<:erlang.crc32(prelude)::32>>

      assert {:error, {:invalid_prelude, 8, 0}} = EventStream.parse_frames(bogus)
    end

    test "a malformed header block is an error" do
      # Header name length runs past the header block.
      headers_bin = <<10, "ab">>
      prelude = <<16 + byte_size(headers_bin)::32, byte_size(headers_bin)::32>>
      body = prelude <> <<:erlang.crc32(prelude)::32>> <> headers_bin

      assert {:error, :malformed_headers} =
               EventStream.parse_frames(body <> <<:erlang.crc32(body)::32>>)
    end

    test "an unknown header value type is an error" do
      headers_bin = <<4, "name", 14, 0, 0>>
      prelude = <<16 + byte_size(headers_bin)::32, byte_size(headers_bin)::32>>
      body = prelude <> <<:erlang.crc32(prelude)::32>> <> headers_bin

      assert {:error, :malformed_headers} =
               EventStream.parse_frames(body <> <<:erlang.crc32(body)::32>>)
    end

    test "decodes every header value type" do
      headers_bin =
        IO.iodata_to_binary([
          # bool true / bool false
          <<1, "t", 0>>,
          <<1, "f", 1>>,
          # byte, short, int, long (signed)
          <<1, "b", 2, -3::signed-8>>,
          <<1, "s", 3, -300::signed-16>>,
          <<1, "i", 4, -70_000::signed-32>>,
          <<1, "l", 5, -5_000_000_000::signed-64>>,
          # byte array, string
          <<2, "ba", 6, 3::16, "xyz">>,
          <<2, "st", 7, 2::16, "ok">>,
          # timestamp, uuid
          <<2, "ts", 8, 1_700_000_000_000::signed-64>>,
          <<2, "id", 9, 0::128>>
        ])

      prelude = <<16 + byte_size(headers_bin)::32, byte_size(headers_bin)::32>>
      body = prelude <> <<:erlang.crc32(prelude)::32>> <> headers_bin
      frame = body <> <<:erlang.crc32(body)::32>>

      assert {:ok, [%{headers: headers, payload: <<>>}], <<>>} = EventStream.parse_frames(frame)

      assert headers == %{
               "t" => true,
               "f" => false,
               "b" => -3,
               "s" => -300,
               "i" => -70_000,
               "l" => -5_000_000_000,
               "ba" => {:bytes, "xyz"},
               "st" => "ok",
               "ts" => {:timestamp, 1_700_000_000_000},
               "id" => {:uuid, <<0::128>>}
             }
    end
  end

  # -- Properties -------------------------------------------------------------

  defp header_name_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 24)
  end

  defp header_value_gen do
    StreamData.one_of([
      StreamData.boolean(),
      StreamData.integer(),
      StreamData.string(:printable, max_length: 64),
      StreamData.map(StreamData.binary(max_length: 32), &{:bytes, &1}),
      StreamData.map(StreamData.integer(), &{:timestamp, &1}),
      StreamData.map(StreamData.binary(length: 16), &{:uuid, &1})
    ])
  end

  defp message_gen do
    StreamData.map(
      {StreamData.map_of(header_name_gen(), header_value_gen(), max_length: 4),
       StreamData.binary(max_length: 256)},
      fn {headers, payload} -> %{headers: headers, payload: payload} end
    )
  end

  property "any message sequence round-trips through encode and parse" do
    check all(messages <- StreamData.list_of(message_gen(), min_length: 1, max_length: 5)) do
      buffer =
        messages
        |> Enum.map(&EventStream.encode_message(&1.headers, &1.payload))
        |> IO.iodata_to_binary()

      assert {:ok, ^messages, <<>>} = EventStream.parse_frames(buffer)
    end
  end

  property "parsing is invariant under transport chunking" do
    check all(
            messages <- StreamData.list_of(message_gen(), min_length: 1, max_length: 4),
            seed <- StreamData.integer(0..1_000_000)
          ) do
      buffer =
        messages
        |> Enum.map(&EventStream.encode_message(&1.headers, &1.payload))
        |> IO.iodata_to_binary()

      # Split the byte stream at pseudo-random points and feed the
      # chunks incrementally, carrying the remainder like the backend's
      # receive loop does.
      chunks = chunk_randomly(buffer, seed)

      {parsed, leftover} =
        Enum.reduce(chunks, {[], <<>>}, fn chunk, {acc, rest} ->
          assert {:ok, messages, rest} = EventStream.parse_frames(rest <> chunk)
          {acc ++ messages, rest}
        end)

      assert leftover == <<>>
      assert parsed == messages
    end
  end

  property "flipping any single byte is a structured error" do
    check all(
            message <- message_gen(),
            position_seed <- StreamData.integer(0..1_000_000)
          ) do
      frame = EventStream.encode_message(message.headers, message.payload)
      flip_at = rem(position_seed, byte_size(frame))
      <<prefix::binary-size(flip_at), byte, suffix::binary>> = frame
      corrupted = <<prefix::binary, Bitwise.bxor(byte, 0xFF), suffix::binary>>

      # A flipped byte lands in a region covered by one of the two
      # CRCs (which detect all bursts <= 32 bits), so corruption can
      # never parse cleanly.
      assert {:error, _reason} = EventStream.parse_frames(corrupted)
    end
  end

  defp chunk_randomly(buffer, seed) do
    chunk_randomly(buffer, :rand.seed_s(:exsss, {seed, 7, 13}), [])
  end

  defp chunk_randomly(<<>>, _state, acc), do: Enum.reverse(acc)

  defp chunk_randomly(buffer, state, acc) do
    {size, state} = :rand.uniform_s(min(byte_size(buffer), 37), state)
    <<chunk::binary-size(size), rest::binary>> = buffer
    chunk_randomly(rest, state, [chunk | acc])
  end
end
