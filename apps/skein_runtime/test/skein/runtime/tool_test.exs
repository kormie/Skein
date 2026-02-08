defmodule Skein.Runtime.ToolTest do
  use ExUnit.Case, async: false

  alias Skein.Runtime.Tool
  alias Skein.Runtime.Trace

  @valid_capabilities [%{kind: "tool.use", params: ["MyTool"]}]
  @no_capabilities []

  setup do
    Trace.clear()
    Tool.clear_registry()
    :ok
  end

  # ------------------------------------------------------------------
  # Tool registration
  # ------------------------------------------------------------------

  describe "register/3" do
    test "registers a tool with name, schema, and implementation" do
      schema = %{input: %{amount: :int}, output: %{id: :string}}
      impl = fn input -> {:ok, %{id: "r_#{input.amount}"}} end

      assert :ok = Tool.register("MyTool", schema, impl)
    end

    test "registered tool appears in list/1" do
      schema = %{input: %{}, output: %{}}
      impl = fn _input -> {:ok, %{}} end

      Tool.register("ToolA", schema, impl)
      Tool.register("ToolB", schema, impl)

      tools = Tool.list(@valid_capabilities)
      assert {:ok, tool_list} = tools
      names = Enum.map(tool_list, & &1.name)
      assert "ToolA" in names
      assert "ToolB" in names
    end
  end

  # ------------------------------------------------------------------
  # call/3
  # ------------------------------------------------------------------

  describe "call/3" do
    setup do
      schema = %{
        input: %{amount: :int, customer_id: :string},
        output: %{id: :string, status: :string}
      }

      impl = fn input ->
        {:ok, %{id: "refund_#{input[:amount]}", status: "pending"}}
      end

      Tool.register("MyTool", schema, impl)
      :ok
    end

    test "returns {:ok, result} on success" do
      assert {:ok, result} =
               Tool.call("MyTool", %{amount: 100, customer_id: "cust_1"}, @valid_capabilities)

      assert result.id == "refund_100"
      assert result.status == "pending"
    end

    test "rejects without tool.use capability" do
      assert {:error, %Tool.Error{kind: :capability_error}} =
               Tool.call("MyTool", %{amount: 100}, @no_capabilities)
    end

    test "returns error for unknown tool" do
      assert {:error, %Tool.Error{kind: :not_found}} =
               Tool.call("UnknownTool", %{}, @valid_capabilities)
    end

    test "returns error when implementation returns error" do
      failing_impl = fn _input -> {:error, "Stripe API down"} end
      Tool.register("FailingTool", %{input: %{}, output: %{}}, failing_impl)

      caps = [%{kind: "tool.use", params: ["FailingTool"]}]

      assert {:error, %Tool.Error{kind: :execution_error}} =
               Tool.call("FailingTool", %{}, caps)
    end

    test "records a trace span with tool metadata" do
      Tool.call("MyTool", %{amount: 100}, @valid_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :tool
      assert span.method == :call
      assert span.name == "MyTool"
      assert span.outcome == :ok
    end

    test "records error trace span on capability failure" do
      Tool.call("MyTool", %{amount: 100}, @no_capabilities)

      spans = Trace.recent_spans(10)
      assert length(spans) >= 1
      span = hd(spans)
      assert span.kind == :tool
      assert span.outcome == :error
    end
  end

  # ------------------------------------------------------------------
  # list/1
  # ------------------------------------------------------------------

  describe "list/1" do
    test "returns {:ok, []} when no tools registered" do
      assert {:ok, []} = Tool.list(@valid_capabilities)
    end

    test "rejects without tool.use capability" do
      assert {:error, %Tool.Error{kind: :capability_error}} =
               Tool.list(@no_capabilities)
    end

    test "returns tool info with name and schema" do
      schema = %{input: %{x: :int}, output: %{y: :int}}
      Tool.register("CalcTool", schema, fn _i -> {:ok, %{}} end)

      assert {:ok, [info]} = Tool.list(@valid_capabilities)
      assert info.name == "CalcTool"
      assert info.schema == schema
    end
  end

  # ------------------------------------------------------------------
  # schema/2
  # ------------------------------------------------------------------

  describe "schema/2" do
    test "returns schema for registered tool" do
      schema = %{input: %{amount: :int}, output: %{id: :string}}
      Tool.register("MyTool", schema, fn _i -> {:ok, %{}} end)

      assert {:ok, ^schema} = Tool.schema("MyTool", @valid_capabilities)
    end

    test "returns error for unknown tool" do
      assert {:error, %Tool.Error{kind: :not_found}} =
               Tool.schema("UnknownTool", @valid_capabilities)
    end

    test "rejects without tool.use capability" do
      assert {:error, %Tool.Error{kind: :capability_error}} =
               Tool.schema("MyTool", @no_capabilities)
    end
  end

  # ------------------------------------------------------------------
  # Tool.Error
  # ------------------------------------------------------------------

  describe "Tool.Error" do
    test "capability_error has reason" do
      error = Tool.Error.capability_error("missing tool.use")
      assert error.kind == :capability_error
      assert error.detail.reason == "missing tool.use"
    end

    test "not_found has tool name" do
      error = Tool.Error.not_found("UnknownTool")
      assert error.kind == :not_found
      assert error.detail.name == "UnknownTool"
    end

    test "execution_error has tool name and reason" do
      error = Tool.Error.execution_error("MyTool", "API timeout")
      assert error.kind == :execution_error
      assert error.detail.tool == "MyTool"
      assert error.detail.error == "API timeout"
    end
  end
end
