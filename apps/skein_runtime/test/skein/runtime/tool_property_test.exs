defmodule Skein.Runtime.ToolPropertyTest do
  @moduledoc """
  Property-based tests for the Skein tool runtime.

  Uses StreamData generators to verify tool call invariants across
  large input spaces: capability checking, tool registration, and
  error handling.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Tool
  alias Skein.Runtime.Trace

  setup do
    Trace.clear()
    Tool.clear_registry()
    :ok
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp tool_name_gen do
    gen all(
          parts <-
            StreamData.list_of(
              StreamData.string(Enum.to_list(?A..?Z) ++ Enum.to_list(?a..?z),
                min_length: 3,
                max_length: 10
              ),
              min_length: 1,
              max_length: 3
            )
        ) do
      parts
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(".")
    end
  end

  defp input_map_gen do
    StreamData.map_of(
      StreamData.atom(:alphanumeric),
      StreamData.one_of([
        StreamData.integer(),
        StreamData.string(:alphanumeric, min_length: 0, max_length: 20),
        StreamData.boolean()
      ]),
      min_length: 0,
      max_length: 5
    )
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "calling any unregistered tool returns not_found error" do
    check all(
            name <- tool_name_gen(),
            input <- input_map_gen()
          ) do
      caps = [%{kind: "tool.use", params: [name]}]

      assert {:error, %Tool.Error{kind: :not_found}} =
               Tool.call(name, input, caps)
    end
  end

  property "calling any tool without capability returns capability_error" do
    check all(
            name <- tool_name_gen(),
            input <- input_map_gen()
          ) do
      Tool.register(name, %{}, fn _i -> {:ok, %{}} end)

      assert {:error, %Tool.Error{kind: :capability_error}} =
               Tool.call(name, input, [])
    end
  end

  property "registered tool always callable with correct capability" do
    check all(
            name <- tool_name_gen(),
            input <- input_map_gen()
          ) do
      Tool.register(name, %{input: %{}, output: %{}}, fn _i -> {:ok, %{result: "ok"}} end)
      caps = [%{kind: "tool.use", params: [name]}]

      assert {:ok, %{result: "ok"}} = Tool.call(name, input, caps)
    end
  end

  property "every tool call produces a trace span" do
    check all(name <- tool_name_gen()) do
      Tool.register(name, %{}, fn _i -> {:ok, %{}} end)
      caps = [%{kind: "tool.use", params: [name]}]

      Trace.clear()
      Tool.call(name, %{}, caps)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :tool
    end
  end

  property "list returns all registered tools" do
    check all(
            names <-
              StreamData.uniq_list_of(tool_name_gen(), min_length: 1, max_length: 5)
          ) do
      Tool.clear_registry()

      for name <- names do
        Tool.register(name, %{}, fn _i -> {:ok, %{}} end)
      end

      caps = [%{kind: "tool.use", params: ["any"]}]
      {:ok, tool_list} = Tool.list(caps)
      listed_names = Enum.map(tool_list, & &1.name) |> MapSet.new()

      for name <- names do
        assert name in listed_names, "Expected #{name} in tool list"
      end
    end
  end
end
