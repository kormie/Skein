defmodule Skein.Integration.SchemaEngineTest do
  @moduledoc """
  End-to-end pins for the one recursive schema engine (C3/#298) at the two
  boundaries the audit found dead:

  - `llm.json[T]` now VALIDATES the parsed response against T's schema — a
    well-formed-JSON response that violates the schema surfaces as
    `Err(LlmError.InvalidSchema(violations))`, matchable from Skein.
  - Tool OUTPUT is validated against the declared output schema — an
    implementation returning the wrong shape is
    `Err(ToolError.ValidationError(...))` with `output:`-prefixed
    violations, not silent nonsense at the caller.

  (`req.json[T]`'s recursive validation is pinned by the runtime
  `json_schema_test.exs` + `request` tests; tool INPUT via the shared
  engine is pinned by the existing tool validation tests.)
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler
  alias Skein.Runtime.{Llm, Tool}

  defmodule WrongShapeBackend do
    @moduledoc "Returns valid JSON that violates any non-trivial schema."
    @behaviour Skein.Runtime.Llm.Backend

    @impl true
    def chat(_model, _system, _input), do: {:ok, ~s({"unexpected": true})}

    @impl true
    def json(_model, _system, _input, _schema), do: {:ok, ~s({"unexpected": true})}

    @impl true
    def stream(_model, _system, _input), do: {:ok, [~s({"unexpected": true})]}

    @impl true
    def embed(_model, _input), do: {:ok, [0.0]}
  end

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("compile failed: #{inspect(errors)}")
    end
  end

  setup do
    previous_backend = Llm.get_backend()
    on_exit(fn -> Llm.set_backend(previous_backend) end)
    :ok
  end

  test "llm.json[T] schema violations surface as Err(LlmError.InvalidSchema(violations))" do
    Llm.set_backend(WrongShapeBackend)

    mod =
      compile!("""
      module Verdicts {
        capability model("anthropic", "claude-opus-4-8")

        type Verdict {
          action: String
          confidence: Int
        }

        fn decide() -> Int {
          match llm.json[Verdict]("claude-opus-4-8", "sys", "input") {
            Ok(_) -> 0
            Err(LlmError.InvalidSchema(violations)) -> List.length(violations)
            Err(_) -> 0 - 1
          }
        }
      }
      """)

    # Both required fields are missing from the backend's response.
    assert mod.decide() == 2
  end

  test "tool output violating its declared schema is Err(ToolError.ValidationError)" do
    Tool.register(
      "Shape.Shifter",
      %{
        input: %{},
        output_schema: %{
          "type" => "object",
          "properties" => %{"count" => %{"type" => "integer"}},
          "required" => ["count"]
        }
      },
      fn _input -> {:ok, %{"count" => "not an int"}} end
    )

    mod =
      compile!("""
      module ShapeCaller {
        capability tool.use(Shape.Shifter)

        fn call_it() -> String {
          match tool.call(Shape.Shifter, {}) {
            Ok(_) -> "ok"
            Err(ToolError.ValidationError(t, violations)) -> "invalid output"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert mod.call_it() == "invalid output"

    # The Elixir-level shape carries the direction-prefixed violations.
    caps = [%{kind: "tool.use", params: ["Shape.Shifter"]}]

    assert {:error, {:validation_error, "Shape.Shifter", violations}} =
             Tool.call("Shape.Shifter", %{}, caps)

    assert Enum.any?(violations, &(&1 =~ "output:"))
    assert Enum.any?(violations, &(&1 =~ "count"))
  end
end
