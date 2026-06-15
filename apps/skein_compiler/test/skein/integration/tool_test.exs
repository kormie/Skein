defmodule Skein.Integration.ToolTest do
  @moduledoc """
  End-to-end integration tests for Phase 6c tool features.

  These tests compile Skein source code through the full pipeline
  (lex → parse → analyze → codegen → BEAM) and exercise the resulting
  modules against the tool runtime.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  setup do
    Skein.Runtime.Tool.clear_registry()
    Skein.Runtime.Trace.clear()
    :ok
  end

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # ------------------------------------------------------------------
  # Tool declaration and metadata
  # ------------------------------------------------------------------

  describe "tool declaration → __tools__ metadata" do
    test "single tool with all fields produces correct metadata" do
      mod =
        compile!("""
        module ToolService {
          tool CreateRefund {
            description: "Issue a refund"

            input {
              customer_id: String
              amount: Int
            }

            output {
              id: String
              status: String
            }

            implement {
              "refund_impl"
            }
          }
        }
        """)

      tools = mod.__tools__()
      assert length(tools) == 1

      [tool] = tools
      assert tool.name == "CreateRefund"
      assert tool.description == "Issue a refund"

      assert [
               %{name: "customer_id", type: "String"},
               %{name: "amount", type: "Int"}
             ] = tool.input

      assert [
               %{name: "id", type: "String"},
               %{name: "status", type: "String"}
             ] = tool.output
    end

    test "multiple tools with dotted names" do
      mod =
        compile!("""
        module PaymentService {
          tool Stripe.CreateRefund {
            input { amount: Int }
            output { id: String }
            implement { "ok" }
          }

          tool Stripe.GetBalance {
            input { account_id: String }
            output { balance: Int }
            implement { 0 }
          }
        }
        """)

      tools = mod.__tools__()
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["Stripe.CreateRefund", "Stripe.GetBalance"]
    end

    test "tool with parameterized types in fields" do
      mod =
        compile!("""
        module ListService {
          tool ProcessItems {
            input { items: List[String] }
            output { results: List[Int] }
            implement { "ok" }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert [%{name: "items", type: "List[String]"}] = tool.input
      assert [%{name: "results", type: "List[Int]"}] = tool.output
    end
  end

  # ------------------------------------------------------------------
  # Tool call through compiled code
  # ------------------------------------------------------------------

  describe "tool.call from compiled Skein code" do
    test "calls a registered tool and returns result" do
      # Register a tool in the runtime
      Skein.Runtime.Tool.register("Greet", %{}, fn input ->
        name = if is_binary(input), do: input, else: inspect(input)
        {:ok, %{greeting: "Hello, #{name}!"}}
      end)

      mod =
        compile!("""
        module ToolCaller {
          capability tool.use(Greet)

          fn invoke(name: String) -> Result[String, String] {
            tool.call(Greet, name)
          }
        }
        """)

      assert {:ok, %{greeting: "Hello, Alice!"}} = mod.invoke("Alice")
    end

    test "returns error for unregistered tool" do
      mod =
        compile!("""
        module ToolCaller2 {
          capability tool.use(Missing)

          fn invoke() -> Result[String, String] {
            tool.call(Missing, "data")
          }
        }
        """)

      assert {:error, error} = mod.invoke()
      assert error.__struct__ == Skein.Runtime.Tool.Error
      assert error.kind == :not_found
    end

    test "tool.call result can be bound with let" do
      Skein.Runtime.Tool.register("Calc", %{}, fn input ->
        n = if is_integer(input), do: input, else: 0
        {:ok, %{doubled: n * 2}}
      end)

      mod =
        compile!("""
        module ToolCalcBind {
          capability tool.use(Calc)

          fn double(n: Int) -> Result[String, String] {
            let result = tool.call(Calc, n)
            result
          }
        }
        """)

      assert {:ok, %{doubled: 10}} = mod.double(5)
    end
  end

  # ------------------------------------------------------------------
  # tool.list and tool.schema from compiled code
  # ------------------------------------------------------------------

  describe "tool.list and tool.schema from compiled code" do
    test "tool.list returns all registered tools" do
      Skein.Runtime.Tool.register("ToolA", %{input: %{}}, fn _i -> {:ok, %{}} end)
      Skein.Runtime.Tool.register("ToolB", %{input: %{}}, fn _i -> {:ok, %{}} end)

      mod =
        compile!("""
        module ToolLister {
          capability tool.use(ToolA)

          fn get_tools() -> Result[List[String], String] {
            tool.list()
          }
        }
        """)

      assert {:ok, tools} = mod.get_tools()
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["ToolA", "ToolB"]
    end

    test "tool.schema returns schema for registered tool" do
      schema = %{input: %{x: :int}, output: %{y: :int}}
      Skein.Runtime.Tool.register("SchemaTool", schema, fn _i -> {:ok, %{}} end)

      mod =
        compile!("""
        module ToolSchemaGetter {
          capability tool.use(SchemaTool)

          fn get_schema() -> Result[String, String] {
            tool.schema(SchemaTool)
          }
        }
        """)

      assert {:ok, ^schema} = mod.get_schema()
    end
  end

  # ------------------------------------------------------------------
  # Tracing integration
  # ------------------------------------------------------------------

  describe "tool tracing" do
    test "tool.call produces trace span with metadata" do
      Skein.Runtime.Tool.register("TracedTool", %{}, fn _i -> {:ok, %{}} end)

      mod =
        compile!("""
        module ToolTraced {
          capability tool.use(TracedTool)

          fn invoke() -> Result[String, String] {
            tool.call(TracedTool, "input")
          }
        }
        """)

      Skein.Runtime.Trace.clear()
      mod.invoke()

      spans = Skein.Runtime.Trace.recent_spans(10)
      tool_spans = Enum.filter(spans, &(&1.kind == :tool))
      assert length(tool_spans) >= 1

      span = hd(tool_spans)
      assert span.kind == :tool
      assert span.method == :call
      assert span.name == "TracedTool"
      assert span.outcome == :ok
      assert is_integer(span.duration_us)
      assert span.duration_us >= 0
    end
  end

  # ------------------------------------------------------------------
  # Tool JSON Schema generation in __tools__/0
  # ------------------------------------------------------------------

  describe "tool JSON Schema in __tools__ metadata" do
    test "tool metadata includes input_schema as JSON Schema object" do
      mod =
        compile!("""
        module ToolSchemaService {
          tool CreateRefund {
            description: "Issue a refund"

            input {
              customer_id: String
              amount: Int
            }

            output {
              id: String
              status: String
            }

            implement {
              "ok"
            }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.input_schema["type"] == "object"
      assert tool.input_schema["properties"]["customer_id"] == %{"type" => "string"}
      assert tool.input_schema["properties"]["amount"] == %{"type" => "integer"}
      assert "customer_id" in tool.input_schema["required"]
      assert "amount" in tool.input_schema["required"]
    end

    test "tool metadata includes output_schema as JSON Schema object" do
      mod =
        compile!("""
        module ToolOutputSchema {
          tool GetBalance {
            input { account_id: String }

            output {
              balance: Int
              currency: String
            }

            implement { "ok" }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.output_schema["type"] == "object"
      assert tool.output_schema["properties"]["balance"] == %{"type" => "integer"}
      assert tool.output_schema["properties"]["currency"] == %{"type" => "string"}
    end

    test "tool with annotated fields includes constraints in schema" do
      mod =
        compile!("""
        module ToolAnnotated {
          tool CreateRefund {
            input {
              customer_id: String @description("Stripe customer ID")
              amount: Int @min(1) @max(100000)
            }

            output { id: String }

            implement { "ok" }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.input_schema["properties"]["customer_id"]["description"] == "Stripe customer ID"
      assert tool.input_schema["properties"]["amount"]["minimum"] == 1
      assert tool.input_schema["properties"]["amount"]["maximum"] == 100_000
    end
  end

  # ------------------------------------------------------------------
  # Tools coexisting with other declarations
  # ------------------------------------------------------------------

  describe "tools with other module features" do
    test "module with tools, functions, capabilities, and handlers" do
      Skein.Runtime.Tool.register("HelperTool", %{}, fn input ->
        {:ok, %{result: "computed_#{input}"}}
      end)

      mod =
        compile!("""
        module FullService {
          capability http.in
          capability tool.use(HelperTool)

          fn helper(x: Int) -> Int {
            x + 1
          }

          tool Compute {
            input { value: Int }
            output { result: String }
            implement { "computed" }
          }

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }
        }
        """)

      # Functions work
      assert mod.helper(5) == 6

      # Tool metadata works
      tools = mod.__tools__()
      assert length(tools) == 1
      assert hd(tools).name == "Compute"

      # Handler metadata works
      handlers = mod.__handlers__()
      assert length(handlers) == 1

      # Capabilities include tool.use
      caps = mod.__capabilities__()
      tool_caps = Enum.filter(caps, &(&1.kind == "tool.use"))
      assert length(tool_caps) == 1
    end
  end

  # ------------------------------------------------------------------
  # Compiled implement blocks + module registration (issue #79)
  # ------------------------------------------------------------------

  describe "tool implement blocks compiled to entry points" do
    test "__tools__ metadata carries the impl entry point" do
      mod =
        compile!("""
        module ImplMetaService {
          tool Meta.Implemented {
            input { x: Int }
            output { y: Int }
            implement { Ok({ y: x }) }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.impl == :__tool_impl_0__
      assert function_exported?(mod, :__tool_impl_0__, 1)
    end

    test "tool without implement block is rejected by the parser" do
      assert {:error, [error | _]} =
               Skein.Compiler.compile_string("""
               module ImplMetaNone {
                 tool Meta.Unimplemented {
                   input { x: Int }
                   output { y: Int }
                 }
               }
               """)

      assert error.message =~ "implement"
    end

    test "impl entry point binds input fields and evaluates the body" do
      mod =
        compile!("""
        module ImplDirectService {
          tool Direct.Add {
            input {
              a: Int
              b: Int
            }
            output { sum: Int }
            implement { Ok({ sum: a + b }) }
          }
        }
        """)

      assert {:ok, %{sum: 5}} = mod.__tool_impl_0__(%{a: 2, b: 3})
    end

    test "implement block can call module-local functions" do
      mod =
        compile!("""
        module ImplLocalFns {
          fn greeting_for(name: String) -> String {
            "Hello, ${name}!"
          }

          tool Local.Greet {
            input { name: String }
            output { greeting: String }
            implement { Ok({ greeting: greeting_for(name) }) }
          }
        }
        """)

      assert {:ok, %{greeting: "Hello, Ada!"}} = mod.__tool_impl_0__(%{name: "Ada"})
    end

    test "each tool's impl entry point follows its declaration index" do
      mod =
        compile!("""
        module ImplMixed {
          tool Mixed.First {
            input { x: Int }
            output { y: Int }
            implement { Ok({ y: x + 1 }) }
          }

          tool Mixed.Second {
            input { x: Int }
            output { y: Int }
            implement { Ok({ y: x + 2 }) }
          }
        }
        """)

      [first, second] = mod.__tools__()
      assert first.impl == :__tool_impl_0__
      assert second.impl == :__tool_impl_1__
      assert {:ok, %{y: 10}} = mod.__tool_impl_0__(%{x: 9})
      assert {:ok, %{y: 11}} = mod.__tool_impl_1__(%{x: 9})
    end
  end

  describe "cross-module tool.call end-to-end (definer + caller)" do
    test "caller invokes a tool registered from another compiled module" do
      definer =
        compile!("""
        module MathToolService {
          tool Math.Add {
            description: "Add two integers"
            input {
              a: Int
              b: Int
            }
            output { sum: Int }
            implement { Ok({ sum: a + b }) }
          }
        }
        """)

      Skein.Runtime.Tool.register_module(definer)

      caller =
        compile!("""
        module MathToolCaller {
          capability tool.use(Math.Add)

          fn add_via_tool(a: Int, b: Int) -> Int {
            let result = tool.call(Math.Add, { a: a, b: b })!
            result.sum
          }
        }
        """)

      assert caller.add_via_tool(2, 3) == 5
    end

    test "caller can match on the tool result" do
      definer =
        compile!("""
        module ParityToolService {
          tool Parity.Check {
            input { n: Int }
            output { even: Bool }
            implement { Ok({ even: n == 0 }) }
          }
        }
        """)

      Skein.Runtime.Tool.register_module(definer)

      caller =
        compile!("""
        module ParityToolCaller {
          capability tool.use(Parity.Check)

          fn check(n: Int) -> String {
            match tool.call(Parity.Check, { n: n }) {
              Ok(r) -> "got result"
              Err(e) -> "tool failed"
            }
          }
        }
        """)

      assert caller.check(0) == "got result"
    end

    test "input validation against the declared schema applies cross-module" do
      definer =
        compile!("""
        module StrictToolService {
          tool Strict.Echo {
            input { message: String }
            output { echoed: String }
            implement { Ok({ echoed: message }) }
          }
        }
        """)

      Skein.Runtime.Tool.register_module(definer)

      caller =
        compile!("""
        module StrictToolCaller {
          capability tool.use(Strict.Echo)

          fn bad_call() -> Result[String, String] {
            tool.call(Strict.Echo, { message: 42 })
          }
        }
        """)

      assert {:error, error} = caller.bad_call()
      assert error.kind == :validation_error
    end

    test "implement Err(...) surfaces as execution_error to the caller" do
      definer =
        compile!("""
        module FailingToolService {
          tool Failing.Always {
            input { reason: String }
            output { ok: Bool }
            errors { ToolFailure }
            implement { Err(ToolFailure.from(reason)) }
          }
        }
        """)

      Skein.Runtime.Tool.register_module(definer)

      caller =
        compile!("""
        module FailingToolCaller {
          capability tool.use(Failing.Always)

          fn call_it() -> Result[String, String] {
            tool.call(Failing.Always, { reason: "nope" })
          }
        }
        """)

      assert {:error, error} = caller.call_it()
      assert error.kind == :execution_error
      assert error.detail.error =~ "tool_failure"
    end

    test "implement match arms route Ok and Err results" do
      definer =
        compile!("""
        module BranchingToolService {
          fn risky(n: Int) -> Result[Int, String] {
            match n {
              0 -> Err("zero not allowed")
              other -> Ok(other)
            }
          }

          tool Branching.Compute {
            input { n: Int }
            output { value: Int }
            implement {
              match risky(n) {
                Ok(v) -> Ok({ value: v })
                Err(e) -> Err(e)
              }
            }
          }
        }
        """)

      Skein.Runtime.Tool.register_module(definer)

      caps = [%{kind: "tool.use", params: ["Branching.Compute"]}]

      assert {:ok, %{value: 7}} =
               Skein.Runtime.Tool.call("Branching.Compute", %{n: 7}, caps)

      assert {:error, error} = Skein.Runtime.Tool.call("Branching.Compute", %{n: 0}, caps)
      assert error.kind == :execution_error
      assert error.detail.error =~ "zero not allowed"
    end
  end

  # ------------------------------------------------------------------
  # Result/enum variant construction in expression position
  # ------------------------------------------------------------------

  describe "variant construction in expression position" do
    test "Ok and Err construct runtime result tuples" do
      mod =
        compile!("""
        module VariantResultExprs {
          fn make_ok(x: Int) -> Result[Int, String] { Ok(x) }
          fn make_err(msg: String) -> Result[Int, String] { Err(msg) }
        }
        """)

      assert mod.make_ok(42) == {:ok, 42}
      assert mod.make_err("boom") == {:error, "boom"}
    end

    test "constructed results round-trip through match patterns" do
      mod =
        compile!("""
        module VariantRoundTrip {
          fn make(n: Int) -> Result[Int, String] {
            match n {
              0 -> Err("zero")
              other -> Ok(other)
            }
          }

          fn classify(n: Int) -> String {
            match make(n) {
              Ok(v) -> "ok"
              Err(e) -> e
            }
          }
        }
        """)

      assert mod.classify(3) == "ok"
      assert mod.classify(0) == "zero"
    end

    test "dotted enum variant construction matches variant patterns" do
      mod =
        compile!("""
        module VariantDotted {
          enum Event {
            Charge(amount: Int)
            Refund(amount: Int)
          }

          fn charge(n: Int) -> Event { Event.Charge(n) }

          fn describe(n: Int) -> String {
            match charge(n) {
              Event.Charge(amount) -> "charged"
              Event.Refund(amount) -> "refunded"
            }
          }
        }
        """)

      assert mod.charge(5) == {:charge, 5}
      assert mod.describe(5) == "charged"
    end

    test "ErrorName.from(cause) wraps the cause in an error variant" do
      # `SearchError` must be declared in a tool `errors {}` block —
      # otherwise `SearchError.from(...)` is a cross-module call (E0016).
      mod =
        compile!("""
        module VariantFrom {
          tool VariantFrom.Search {
            input { q: String }
            output { r: String }
            errors { SearchError }
            implement { Ok({ r: q }) }
          }

          fn wrap(cause: String) -> String {
            SearchError.from(cause)
          }
        }
        """)

      assert mod.wrap("timeout") == {:search_error, "timeout"}
    end

    test "undeclared ErrorName.from(cause) is rejected as a cross-module call" do
      assert {:error, [error | _]} =
               Skein.Compiler.compile_string("""
               module VariantFromUndeclared {
                 fn wrap(cause: String) -> String {
                   SearchError.from(cause)
                 }
               }
               """)

      assert error.code == "E0016"
    end
  end

  # ------------------------------------------------------------------
  # Tool identifier references — end-to-end (capability-as-import)
  # ------------------------------------------------------------------

  describe "tool identifier references end-to-end" do
    test "tool.call with identifier goes through full pipeline" do
      Skein.Runtime.Tool.register("Greet", %{}, fn input ->
        name = if is_binary(input), do: input, else: inspect(input)
        {:ok, %{greeting: "Hello, #{name}!"}}
      end)

      mod =
        compile!("""
        module ToolCallerIdent {
          capability tool.use(Greet)

          fn invoke(name: String) -> Result[String, String] {
            tool.call(Greet, name)
          }
        }
        """)

      assert {:ok, %{greeting: "Hello, Alice!"}} = mod.invoke("Alice")
    end

    test "tool.call with dotted identifier end-to-end" do
      Skein.Runtime.Tool.register("Stripe.Refund", %{}, fn input ->
        {:ok, %{id: "ref_#{input}"}}
      end)

      mod =
        compile!("""
        module DottedToolCaller {
          capability tool.use(Stripe.Refund)

          fn refund(data: String) -> Result[String, String] {
            tool.call(Stripe.Refund, data)
          }
        }
        """)

      assert {:ok, %{id: "ref_123"}} = mod.refund("123")
    end

    test "tool.schema with identifier end-to-end" do
      schema = %{input: %{x: :int}, output: %{y: :int}}
      Skein.Runtime.Tool.register("SchemaTool", schema, fn _i -> {:ok, %{}} end)

      mod =
        compile!("""
        module SchemaToolIdent {
          capability tool.use(SchemaTool)

          fn get_schema() -> Result[String, String] {
            tool.schema(SchemaTool)
          }
        }
        """)

      assert {:ok, ^schema} = mod.get_schema()
    end

    test "module with tool declaration and identifier-based tool.call" do
      Skein.Runtime.Tool.register("HelperTool", %{}, fn input ->
        {:ok, %{result: "computed_#{input}"}}
      end)

      mod =
        compile!("""
        module FullServiceIdent {
          capability http.in
          capability tool.use(HelperTool)

          tool Compute {
            input { value: Int }
            output { result: String }
            implement { "computed" }
          }

          fn invoke(x: String) -> Result[String, String] {
            tool.call(HelperTool, x)
          }

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }
        }
        """)

      # Tool call works
      assert {:ok, %{result: "computed_test"}} = mod.invoke("test")

      # Tool metadata still works
      tools = mod.__tools__()
      assert length(tools) == 1
      assert hd(tools).name == "Compute"
    end

    test "tool.call identifier trace records correct tool name" do
      Skein.Runtime.Tool.register("TracedIdent", %{}, fn _i -> {:ok, %{}} end)
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TracedIdentService {
          capability tool.use(TracedIdent)

          fn invoke() -> Result[String, String] {
            tool.call(TracedIdent, "input")
          }
        }
        """)

      mod.invoke()

      spans = Skein.Runtime.Trace.recent_spans(10)
      tool_spans = Enum.filter(spans, &(&1.kind == :tool))
      assert length(tool_spans) >= 1
      assert hd(tool_spans).name == "TracedIdent"
    end
  end
end
