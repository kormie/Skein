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
          capability tool.use("Greet")

          fn invoke(name: String) -> String {
            tool.call("Greet", name)
          }
        }
        """)

      assert {:ok, %{greeting: "Hello, Alice!"}} = mod.invoke("Alice")
    end

    test "returns error for unregistered tool" do
      mod =
        compile!("""
        module ToolCaller2 {
          capability tool.use("Missing")

          fn invoke() -> String {
            tool.call("Missing", "data")
          }
        }
        """)

      assert {:error, %Skein.Runtime.Tool.Error{kind: :not_found}} = mod.invoke()
    end

    test "tool.call result can be bound with let" do
      Skein.Runtime.Tool.register("Calc", %{}, fn input ->
        n = if is_integer(input), do: input, else: 0
        {:ok, %{doubled: n * 2}}
      end)

      mod =
        compile!("""
        module ToolCalcBind {
          capability tool.use("Calc")

          fn double(n: Int) -> String {
            let result = tool.call("Calc", n)
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
          capability tool.use("ToolA")

          fn get_tools() -> String {
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
          capability tool.use("SchemaTool")

          fn get_schema() -> String {
            tool.schema("SchemaTool")
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
          capability tool.use("TracedTool")

          fn invoke() -> String {
            tool.call("TracedTool", "input")
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
          capability tool.use("HelperTool")

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
end
