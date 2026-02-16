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
      caps = [%{kind: "tool.use", params: ["UnknownTool"]}]

      assert {:error, %Tool.Error{kind: :not_found}} =
               Tool.call("UnknownTool", %{}, caps)
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
      caps = [%{kind: "tool.use", params: ["UnknownTool"]}]

      assert {:error, %Tool.Error{kind: :not_found}} =
               Tool.schema("UnknownTool", caps)
    end

    test "rejects without tool.use capability" do
      assert {:error, %Tool.Error{kind: :capability_error}} =
               Tool.schema("MyTool", @no_capabilities)
    end
  end

  # ------------------------------------------------------------------
  # Input validation
  # ------------------------------------------------------------------

  describe "input validation" do
    setup do
      schema = %{
        input: %{amount: :int, customer_id: :string},
        output: %{id: :string}
      }

      impl = fn input -> {:ok, %{id: "r_#{input[:amount]}"}} end
      Tool.register("ValidatedTool", schema, impl)
      :ok
    end

    @validated_caps [%{kind: "tool.use", params: ["ValidatedTool"]}]

    test "valid input passes validation" do
      assert {:ok, _} =
               Tool.call("ValidatedTool", %{amount: 100, customer_id: "cust_1"}, @validated_caps)
    end

    test "wrong type for integer field is rejected" do
      assert {:error, %Tool.Error{kind: :validation_error} = err} =
               Tool.call("ValidatedTool", %{amount: "not_an_int", customer_id: "cust_1"}, @validated_caps)

      assert Enum.any?(err.detail.violations, &String.contains?(&1, "amount"))
    end

    test "wrong type for string field is rejected" do
      assert {:error, %Tool.Error{kind: :validation_error} = err} =
               Tool.call("ValidatedTool", %{customer_id: 42}, @validated_caps)

      assert Enum.any?(err.detail.violations, &String.contains?(&1, "customer_id"))
    end

    test "extra fields are allowed (not rejected)" do
      assert {:ok, _} =
               Tool.call("ValidatedTool", %{amount: 100, customer_id: "c", extra: true}, @validated_caps)
    end

    test "missing optional fields are allowed" do
      assert {:ok, _} =
               Tool.call("ValidatedTool", %{amount: 100}, @validated_caps)
    end

    test "tool with no input schema skips validation" do
      Tool.register("NoSchema", %{}, fn _i -> {:ok, %{done: true}} end)
      caps = [%{kind: "tool.use", params: ["NoSchema"]}]
      assert {:ok, _} = Tool.call("NoSchema", %{anything: "goes"}, caps)
    end

    test "validation_error includes tool name and violation details" do
      assert {:error, %Tool.Error{kind: :validation_error, detail: detail}} =
               Tool.call("ValidatedTool", %{amount: "bad"}, @validated_caps)

      assert detail.tool == "ValidatedTool"
      assert is_list(detail.violations)
      assert length(detail.violations) > 0
    end
  end

  # ------------------------------------------------------------------
  # Input validation — extended type coverage
  # ------------------------------------------------------------------

  describe "input validation — all simple types" do
    setup do
      Tool.clear_registry()
      :ok
    end

    @all_caps [%{kind: "tool.use", params: []}]

    test "float field accepts float and integer" do
      Tool.register("FloatTool", %{input: %{score: :float}}, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("FloatTool", %{score: 3.14}, @all_caps)
      assert {:ok, _} = Tool.call("FloatTool", %{score: 42}, @all_caps)
    end

    test "float field rejects string" do
      Tool.register("FloatTool2", %{input: %{score: :float}}, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error}} =
               Tool.call("FloatTool2", %{score: "high"}, @all_caps)
    end

    test "bool field accepts true/false" do
      Tool.register("BoolTool", %{input: %{active: :bool}}, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("BoolTool", %{active: true}, @all_caps)
      assert {:ok, _} = Tool.call("BoolTool", %{active: false}, @all_caps)
    end

    test "bool field rejects non-boolean" do
      Tool.register("BoolTool2", %{input: %{active: :bool}}, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error}} =
               Tool.call("BoolTool2", %{active: 1}, @all_caps)
    end

    test "int field rejects float" do
      Tool.register("IntTool", %{input: %{count: :int}}, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error}} =
               Tool.call("IntTool", %{count: 3.5}, @all_caps)
    end

    test "string field rejects atom" do
      Tool.register("StrTool", %{input: %{name: :string}}, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error}} =
               Tool.call("StrTool", %{name: :hello}, @all_caps)
    end

    test "multiple type violations reported together" do
      Tool.register("MultiErr", %{input: %{a: :int, b: :string}}, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error, detail: detail}} =
               Tool.call("MultiErr", %{a: "bad", b: 42}, @all_caps)
      assert length(detail.violations) == 2
    end
  end

  describe "input validation — JSON Schema format" do
    setup do
      Tool.clear_registry()
      :ok
    end

    @all_caps [%{kind: "tool.use", params: []}]

    test "validates JSON Schema string type" do
      schema = %{"input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}}
      Tool.register("JsonStr", schema, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("JsonStr", %{"name" => "Alice"}, @all_caps)
    end

    test "rejects missing required field in JSON Schema" do
      schema = %{"input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}}
      Tool.register("JsonReq", schema, fn i -> {:ok, i} end)
      assert {:error, %Tool.Error{kind: :validation_error, detail: d}} =
               Tool.call("JsonReq", %{}, @all_caps)
      assert Enum.any?(d.violations, &String.contains?(&1, "name"))
    end

    test "validates JSON Schema integer type" do
      schema = %{"input_schema" => %{"type" => "object", "properties" => %{"count" => %{"type" => "integer"}}, "required" => []}}
      Tool.register("JsonInt", schema, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("JsonInt", %{"count" => 5}, @all_caps)
      assert {:error, _} = Tool.call("JsonInt", %{"count" => "five"}, @all_caps)
    end

    test "validates JSON Schema number type" do
      schema = %{"input_schema" => %{"type" => "object", "properties" => %{"score" => %{"type" => "number"}}, "required" => []}}
      Tool.register("JsonNum", schema, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("JsonNum", %{"score" => 3.14}, @all_caps)
      assert {:ok, _} = Tool.call("JsonNum", %{"score" => 42}, @all_caps)
      assert {:error, _} = Tool.call("JsonNum", %{"score" => "high"}, @all_caps)
    end

    test "validates JSON Schema boolean type" do
      schema = %{"input_schema" => %{"type" => "object", "properties" => %{"flag" => %{"type" => "boolean"}}, "required" => []}}
      Tool.register("JsonBool", schema, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("JsonBool", %{"flag" => true}, @all_caps)
      assert {:error, _} = Tool.call("JsonBool", %{"flag" => "yes"}, @all_caps)
    end

    test "atom-keyed input matches string-keyed JSON Schema via flexible access" do
      schema = %{input_schema: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}}
      Tool.register("JsonFlex", schema, fn i -> {:ok, i} end)
      assert {:ok, _} = Tool.call("JsonFlex", %{name: "Alice"}, @all_caps)
    end
  end

  describe "input validation — edge cases" do
    setup do
      Tool.clear_registry()
      :ok
    end

    @all_caps [%{kind: "tool.use", params: []}]

    test "nil input with no schema passes" do
      Tool.register("NilOk", %{}, fn _i -> {:ok, %{}} end)
      assert {:ok, _} = Tool.call("NilOk", nil, @all_caps)
    end

    test "empty map input with schema passes (all optional)" do
      Tool.register("EmptyIn", %{input: %{x: :int}}, fn _i -> {:ok, %{}} end)
      assert {:ok, _} = Tool.call("EmptyIn", %{}, @all_caps)
    end

    test "non-map input with simple schema passes (check_fields fallback)" do
      Tool.register("NonMap", %{input: %{x: :int}}, fn _i -> {:ok, %{}} end)
      assert {:ok, _} = Tool.call("NonMap", "just a string", @all_caps)
    end

    test "empty input schema map skips validation" do
      Tool.register("EmptySchema", %{input: %{}}, fn _i -> {:ok, %{}} end)
      assert {:ok, _} = Tool.call("EmptySchema", %{bad: :data}, @all_caps)
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
