defmodule Skein.Integration.ScenarioEnvelopeExecTest do
  @moduledoc """
  End-to-end execution of scenario capability environments (#282): a scenario's
  `implement` provider controls the effect a tool exercises. Here a `uuid`
  provider makes the tool's `uuid.new()` deterministic — proving codegen builds
  the envelope, `tool.call` pushes it, and effect resolution serves the provider.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler
  alias Skein.Runtime.{CapabilityStack, Tool}

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("compile failed: #{inspect(errors)}")
    end
  end

  setup do
    Tool.clear_registry()
    CapabilityStack.clear()

    on_exit(fn ->
      Tool.clear_registry()
      CapabilityStack.clear()
    end)

    :ok
  end

  test "a scenario uuid provider controls the tool's uuid.new() end to end" do
    mod =
      compile!("""
      module ScenarioUuid {
        capability tool.use(Ids.New)
        capability uuid

        tool Ids.New {
          input { kind: String }
          output { id: Uuid }
          implement { Ok({ id: uuid.new() }) }
        }

        scenario "controlled uuid" {
          capability tool.use(Ids.New) {
            capability uuid {
              implement() -> Uuid { Uuid.parse("00000000-0000-4000-8000-000000000001")! }
            }
          }
          expect {
            let r = tool.call(Ids.New, { kind: "x" })!
            assert "${r.id}" == "00000000-0000-4000-8000-000000000001"
          }
        }
      }
      """)

    Tool.register_module(mod)

    # The scenario test fn registers the envelope, calls the tool, and asserts
    # the minted uuid equals the provider's value. A live uuid would not match,
    # so :ok proves the provider was used.
    assert mod.__test_0__() == :ok

    # The envelope registration does not leak past the scenario body.
    assert CapabilityStack.depth() == 0
  end
end
