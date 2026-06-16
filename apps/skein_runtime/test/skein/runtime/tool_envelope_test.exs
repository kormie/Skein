defmodule Skein.Runtime.ToolEnvelopeTest do
  @moduledoc """
  Runtime wiring of scenario capability envelopes (#282): `tool.call` pushes the
  registered envelope for the tool, and effect resolution (here `uuid`) consults
  the envelope's `implement` provider first. In production no envelope is
  registered, so `tool.call` is unaffected.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.{CapabilityStack, Dependencies, Tool}

  setup do
    Tool.clear_registry()
    CapabilityStack.clear()
    on_exit(fn -> CapabilityStack.clear() end)
    :ok
  end

  @caps [%{kind: "tool.use", params: ["Ids.New"]}]

  defp register_uuid_tool do
    Tool.register("Ids.New", %{}, fn _input -> {:ok, %{id: Dependencies.uuid()}} end)
  end

  test "tool.call pushes the registered envelope; uuid resolves from the provider" do
    register_uuid_tool()

    CapabilityStack.register_envelopes(%{
      "Ids.New" => %{
        tool: "Ids.New",
        providers: %{"uuid" => fn -> "PROVIDED-UUID" end},
        nested: %{}
      }
    })

    assert {:ok, %{id: "PROVIDED-UUID"}} = Tool.call("Ids.New", %{}, @caps)
  end

  test "the envelope is popped after the call returns" do
    register_uuid_tool()

    CapabilityStack.register_envelopes(%{
      "Ids.New" => %{tool: "Ids.New", providers: %{"uuid" => fn -> "X" end}, nested: %{}}
    })

    assert {:ok, _} = Tool.call("Ids.New", %{}, @caps)
    assert CapabilityStack.depth() == 0
    assert CapabilityStack.current() == nil
  end

  test "without a registered envelope, tool.call runs unchanged (live uuid)" do
    register_uuid_tool()

    assert {:ok, %{id: id}} = Tool.call("Ids.New", %{}, @caps)
    # A live v4 UUID, not a provider value.
    assert is_binary(id)
    assert id != "PROVIDED-UUID"
    assert String.length(id) == 36
  end

  test "a nested tool envelope controls a nested tool.call's effects" do
    # Outer tool calls the inner tool; the inner tool mints a uuid. The nested
    # envelope under Outer controls Inner's uuid provider.
    Tool.register("Inner.Make", %{}, fn _input -> {:ok, %{id: Dependencies.uuid()}} end)

    Tool.register("Outer.Run", %{}, fn _input ->
      caps = [%{kind: "tool.use", params: ["Inner.Make"]}]
      {:ok, inner} = Tool.call("Inner.Make", %{}, caps)
      {:ok, %{inner_id: inner.id}}
    end)

    CapabilityStack.register_envelopes(%{
      "Outer.Run" => %{
        tool: "Outer.Run",
        providers: %{},
        nested: %{
          "Inner.Make" => %{
            tool: "Inner.Make",
            providers: %{"uuid" => fn -> "NESTED-UUID" end},
            nested: %{}
          }
        }
      }
    })

    caps = [%{kind: "tool.use", params: ["Outer.Run"]}]
    assert {:ok, %{inner_id: "NESTED-UUID"}} = Tool.call("Outer.Run", %{}, caps)
    assert CapabilityStack.depth() == 0
  end
end
