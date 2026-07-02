defmodule Skein.LlmSchemaFlowTest do
  @moduledoc """
  Verifies that the JSON Schema derived from a `type` declaration flows
  into `llm.json[T]` requests — from module functions and from nested
  agent phase handlers (issue #70).
  """
  use ExUnit.Case, async: false

  # Generated and loaded at test runtime by the Skein compiler — does not
  # exist when this file is compiled. Scoped exception; other undefined
  # module references still warn.
  @compile {:no_warn_undefined, Skein.Agent.SchemaFromAgent.Decider}

  alias Skein.Compiler

  defmodule SchemaRecordingBackend do
    @moduledoc false
    @behaviour Skein.Runtime.Llm.Backend

    @impl true
    def chat(_model, _system, _input), do: {:ok, "ok"}

    @impl true
    def json(_model, _system, _input, schema) do
      :persistent_term.put({__MODULE__, :captured_schema}, schema)
      # A schema-complete response — llm.json[T] validates it since C3 (#298).
      {:ok, %{"action" => "approve", "amount" => 0}}
    end

    def captured_schema do
      :persistent_term.get({__MODULE__, :captured_schema}, :not_called)
    end

    def reset do
      :persistent_term.put({__MODULE__, :captured_schema}, :not_called)
    end
  end

  setup do
    SchemaRecordingBackend.reset()
    Skein.Runtime.Llm.set_backend(SchemaRecordingBackend)
    on_exit(fn -> Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend) end)
    :ok
  end

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  test "module fn: llm.json[T] passes the derived schema to the backend" do
    mod =
      compile!("""
      module SchemaFromFn {
        capability model("anthropic", "claude-opus-4-8")

        type Decision {
          action: String
          amount: Int @min(0)
        }

        fn decide(ticket: String) -> Result[Decision, LlmError] {
          llm.json[Decision](model: "claude-opus-4-8", system: "Decide.", input: ticket)
        }
      }
      """)

    assert {:ok, _} = mod.decide("refund?")

    schema = SchemaRecordingBackend.captured_schema()
    assert %{} = schema
    assert schema != :not_called

    properties = schema["properties"] || schema[:properties]
    assert is_map(properties)
    assert Map.has_key?(properties, "action") or Map.has_key?(properties, :action)
  end

  test "module fn: llm.json[T] schema inlines nested record-typed fields" do
    mod =
      compile!("""
      module SchemaNested {
        capability model("anthropic", "claude-opus-4-8")

        type Inner { a: String }
        type Outer { inner: Inner }

        fn run(x: String) -> String {
          let o = llm.json[Outer](model: "claude-opus-4-8", system: "s", input: x)!
          o.inner.a
        }
      }
      """)

    # Use the deterministic test backend, which synthesizes a value shaped
    # like the schema. The nested field must be inlined in the schema so the
    # backend produces a nested object (not an empty map) and the runtime
    # coerces it to atom keys — otherwise `o.inner.a` crashes with a KeyError.
    Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

    assert mod.run("anything") == "test"
  end

  test "nested agent phase handler: llm.json[T] passes the module type's schema" do
    compile!("""
    module SchemaFromAgent {
      capability model("anthropic", "claude-opus-4-8")

      type Verdict {
        action: String
      }

      agent Decider {
        state { ticket: String }
        enum Phase {
          Analyze -> [Done]
          Done -> []
        }
        on start(ticket: String) -> { transition(Phase.Analyze) }
        on phase(Phase.Analyze) -> {
          let verdict = llm.json[Verdict](
            model: "claude-opus-4-8",
            system: "Decide.",
            input: "ticket"
          )!
          transition(Phase.Done)
        }
        on phase(Phase.Done) -> { stop() }
      }
    }
    """)

    agent_mod = Skein.Agent.SchemaFromAgent.Decider

    assert {:transition, :done, _state, _events} =
             agent_mod.__phase_handler__(:analyze, %{}, [])

    schema = SchemaRecordingBackend.captured_schema()
    assert schema != :not_called

    properties = schema["properties"] || schema[:properties]
    assert is_map(properties)
    assert Map.has_key?(properties, "action") or Map.has_key?(properties, :action)
  end
end
