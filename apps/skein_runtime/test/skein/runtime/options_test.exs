defmodule Skein.Runtime.OptionsTest do
  @moduledoc """
  Deep Option-stripping for serialization boundaries (#294 / B5).

  In-language, optional record fields are total: `{:some, v}` / `:none`.
  On the wire they are bare values / absent keys (mirroring how JSON decode
  tags them back). `strip/1` converts the in-language representation to the
  wire representation wherever user values get JSON-encoded.
  """
  use ExUnit.Case, async: true

  alias Skein.Runtime.Options

  test "unwraps Some values" do
    assert Options.strip({:some, "Bob"}) == "Bob"
  end

  test "top-level None becomes nil" do
    assert Options.strip(:none) == nil
  end

  test "None-valued map keys are omitted (absent field round-trips to None)" do
    assert Options.strip(%{name: "ada", nickname: :none}) == %{name: "ada"}
  end

  test "Some-valued map keys unwrap in place" do
    assert Options.strip(%{name: "ada", nickname: {:some, "Bob"}}) ==
             %{name: "ada", nickname: "Bob"}
  end

  test "recurses through nested maps and lists" do
    value = %{
      users: [
        %{name: "ada", nickname: {:some, "Bob"}},
        %{name: "gus", nickname: :none}
      ],
      meta: %{tag: {:some, %{inner: :none}}}
    }

    assert Options.strip(value) == %{
             users: [%{name: "ada", nickname: "Bob"}, %{name: "gus"}],
             meta: %{tag: %{}}
           }
  end

  test "plain values pass through unchanged" do
    assert Options.strip("s") == "s"
    assert Options.strip(42) == 42
    assert Options.strip(true) == true
    assert Options.strip([1, 2]) == [1, 2]
    assert Options.strip(%{a: 1}) == %{a: 1}
  end
end
