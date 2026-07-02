defmodule Skein.Integration.StructuredErrorABITest do
  @moduledoc """
  End-to-end pins for the structured-error ABI (C2/#297): compiled Skein
  programs pattern-match the error variants the runtime actually returns —
  the exact drift class the 2026-06-19 audit found (an `Err(LlmError.…)`
  arm that compiled but could never match a runtime `%Llm.Error{}` struct).

  Each test compiles Skein source whose match arms name SPECIFIC nominal
  variants (never a catch-all), runs it against the real runtime, and
  asserts the variant arm fired.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler
  alias Skein.Runtime.Tool

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  setup_all do
    previous_backend = Skein.Runtime.Llm.get_backend()
    Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)
    on_exit(fn -> Skein.Runtime.Llm.set_backend(previous_backend) end)
    :ok
  end

  test "LlmError.Denied matches a runtime model-scope denial" do
    mod =
      compile!("""
      module LlmDenied {
        capability model("anthropic", "claude-opus-4-8")

        fn ask_wrong_model() -> String {
          match llm.chat("undeclared-model", "sys", "hi") {
            Ok(text) -> text
            Err(LlmError.Denied(reason)) -> "denied: ${reason}"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert "denied: " <> reason = mod.ask_wrong_model()
    assert reason =~ "undeclared-model"
  end

  test "ToolError.NotFound(name) matches a runtime unknown-tool error" do
    mod =
      compile!("""
      module ToolMissing {
        capability tool.use(Ghost.Tool)

        fn call_missing() -> String {
          match tool.call(Ghost.Tool, { x: 1 }) {
            Ok(_) -> "ok"
            Err(ToolError.NotFound(name)) -> "missing: ${name}"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert mod.call_missing() == "missing: Ghost.Tool"
  end

  test "ToolError.ValidationError carries the violations list" do
    Tool.register("Abi.Echo", %{input: %{count: :int}}, fn input -> {:ok, input} end)

    mod =
      compile!("""
      module ToolInvalid {
        capability tool.use(Abi.Echo)

        fn call_badly() -> Int {
          match tool.call(Abi.Echo, { count: "not an int" }) {
            Ok(_) -> 0
            Err(ToolError.ValidationError(t, violations)) -> List.length(violations)
            Err(_) -> 0 - 1
          }
        }
      }
      """)

    assert mod.call_badly() == 1
  end

  test "StoreError: NotFound (bare and qualified) and Denied match" do
    mod =
      compile!("""
      module StoreMiss {
        capability store.table("abi_things")
        capability uuid

        fn read_missing() -> String {
          match store.abi_things.get(uuid.new()) {
            Ok(_) -> "found"
            Err(NotFound) -> "missing"
            Err(_) -> "other"
          }
        }

        fn read_missing_qualified() -> String {
          match store.abi_things.get(uuid.new()) {
            Ok(_) -> "found"
            Err(StoreError.NotFound) -> "missing"
            Err(_) -> "other"
          }
        }
      }
      """)

    # Runtime store/memory denials are defense-in-depth behind the
    # compile-time capability gate (E0012 rejects undeclared tables), so the
    # Denied leg is pinned at the runtime layer (effect_abi_matrix_test).
    assert mod.read_missing() == "missing"
    assert mod.read_missing_qualified() == "missing"
  end

  test "MemoryError.NotFound matches a memory.get miss" do
    mod =
      compile!("""
      module MemMiss {
        capability memory.kv("abi_ns")

        fn read_missing() -> String {
          match memory.get("never_written_key") {
            Ok(_) -> "found"
            Err(MemoryError.NotFound) -> "missing"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert mod.read_missing() == "missing"
  end

  test "HttpError.Denied matches an undeclared-host denial" do
    mod =
      compile!("""
      module HttpDenied {
        capability http.out("api.example.com")

        fn fetch_elsewhere() -> String {
          match http.get("https://not-declared.example.net/x") {
            Ok(_) -> "ok"
            Err(HttpError.Denied(reason)) -> "denied"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert mod.fetch_elsewhere() == "denied"
  end

  test "a scenario provider's Err(LlmError.RateLimit(ms)) round-trips to a matching arm" do
    mod =
      compile!("""
      module ProviderErrs {
        capability model("anthropic", "claude-opus-4-8")
        capability tool.use(Asker.Ask)

        tool Asker.Ask {
          description: "ask the model"
          input { q: String }
          output { note: String }
          errors { AskError }
          implement {
            match llm.chat("claude-opus-4-8", "sys", q) {
              Ok(text) -> Ok({ note: text })
              Err(LlmError.RateLimit(ms)) -> Ok({ note: "rate limited ${ms}" })
              Err(_) -> Err(AskError.from("other"))
            }
          }
        }

        scenario "provider error is matchable" {
          capability tool.use(Asker.Ask) {
            capability model("anthropic", "claude-opus-4-8") {
              implement(req: LlmRequest) -> Result[LlmResponse, LlmError] {
                Err(LlmError.RateLimit(1500))
              }
            }
          }
          expect {
            let r = tool.call(Asker.Ask, { q: "hi" })!
            assert r.note == "rate limited 1500"
          }
        }
      }
      """)

    Tool.register_module(mod)
    assert mod.__test_0__() == :ok
  end

  test "PublishError.Denied matches an undeclared-topic denial" do
    mod =
      compile!("""
      module PubDenied {
        capability topic.publish("declared_topic")

        fn publish_elsewhere() -> String {
          match topic.publish("other_topic", { a: 1 }) {
            Ok(name) -> name
            Err(PublishError.Denied(reason)) -> "denied"
            Err(_) -> "other"
          }
        }
      }
      """)

    assert mod.publish_elsewhere() == "denied"
  end
end
