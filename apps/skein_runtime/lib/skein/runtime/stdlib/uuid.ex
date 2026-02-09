defmodule Skein.Runtime.Stdlib.Uuid do
  @moduledoc """
  Standard library functions for the Skein `Uuid` type.

  UUIDs are represented as binary strings (e.g., "550e8400-e29b-41d4-a716-446655440000").
  Uses a pure-Erlang v4 (random) UUID generator — no external deps.
  """

  import Bitwise

  @spec new() :: binary()
  def new do
    # Generate v4 (random) UUID
    <<a::32, b::16, _c::4, c::12, _d::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    # Set version (4) and variant (10xx)
    hex =
      :io_lib.format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c, 0x8000 ||| (d &&& 0x3FFF), e]
      )

    IO.iodata_to_binary(hex)
  end

  @spec parse(binary()) :: {:ok, binary()} | {:error, binary()}
  def parse(s) when is_binary(s) do
    # Validate UUID format: 8-4-4-4-12 hex chars
    case Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, s) do
      true -> {:ok, String.downcase(s)}
      false -> {:error, "invalid UUID: #{s}"}
    end
  end

  @spec to_string(binary()) :: binary()
  def to_string(uuid) when is_binary(uuid), do: uuid
end
