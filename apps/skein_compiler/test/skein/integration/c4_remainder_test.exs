defmodule Skein.Integration.C4RemainderTest do
  @moduledoc """
  The two verified remainders of #279 (C4), end to end:

  1. **`llm.embed` under a scenario `model` envelope** resolves PAST the
     chat-shaped `implement` provider — `LlmResponse` is text-only, so there
     is no embed provider form — landing on the deterministic test backend
     instead of erroring (spec §6.4).

  2. **`given` as the home for stateful fixtures** (spec §3.10): its
     bindings evaluate in order before `expect`, in the same scope, so a
     `store.put` in `given` pre-populates the scenario-local store the tool
     under test reads.
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
    Skein.Runtime.Store.clear_all()

    previous_backend = Skein.Runtime.Llm.get_backend()
    Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

    on_exit(fn ->
      Tool.clear_registry()
      CapabilityStack.clear()
      Skein.Runtime.Store.clear_all()
      Skein.Runtime.Llm.set_backend(previous_backend)
    end)

    :ok
  end

  test "llm.embed inside a scenario model envelope resolves to the deterministic backend" do
    mod =
      compile!("""
      module Embedder {
        capability model("anthropic", "claude-opus-4-8")
        capability model("voyage", "voyage-3-large")
        capability tool.use(Embed.Text)

        tool Embed.Text {
          description: "embed a text and report the vector width"
          input { text: String }
          output { dims: Int }
          errors { EmbedError }
          implement {
            match llm.embed("voyage-3-large", text) {
              Ok(vector) -> Ok({ dims: List.length(vector) })
              Err(e) -> Err(EmbedError.from(e))
            }
          }
        }

        scenario "embed works under a chat-shaped model provider" {
          capability tool.use(Embed.Text) {
            capability model("anthropic", "claude-opus-4-8") {
              implement(req: LlmRequest) -> Result[LlmResponse, LlmError] {
                Ok(LlmResponse { text: "never used by embed" })
              }
            }
          }
          expect {
            let r = tool.call(Embed.Text, { text: "hello world" })!
            assert r.dims > 0
          }
        }
      }
      """)

    Tool.register_module(mod)

    # Before #279 this errored ("llm.embed has no implement provider");
    # now embed resolves past the provider to the test backend's
    # deterministic vector.
    assert mod.__test_0__() == :ok
    assert CapabilityStack.depth() == 0
  end

  test "given seeds the scenario-local store before expect runs" do
    mod =
      compile!("""
      module Fixtures {
        capability store.table("fixture_rows", Row)
        capability uuid
        capability tool.use(Count.Rows)

        type Row {
          id: Uuid @primary
          label: String
        }

        tool Count.Rows {
          description: "count the fixture rows"
          input { table: String }
          output { count: Int }
          errors { CountError }
          implement {
            match store.fixture_rows.query({}) {
              Ok(rows) -> Ok({ count: List.length(rows) })
              Err(e) -> Err(CountError.from(e))
            }
          }
        }

        scenario "the tool sees rows seeded by given" {
          capability tool.use(Count.Rows) {
            capability store.table("fixture_rows")
          }
          given {
            first: store.fixture_rows.put(Row { id: uuid.new(), label: "one" })!
            second: store.fixture_rows.put(Row { id: uuid.new(), label: "two" })!
          }
          expect {
            let r = tool.call(Count.Rows, { table: "fixture_rows" })!
            assert r.count == 2
          }
        }
      }
      """)

    Tool.register_module(mod)
    assert mod.__test_0__() == :ok
    assert CapabilityStack.depth() == 0
  end
end
