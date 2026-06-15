defmodule Skein.Integration.MemoryLlmTest do
  @moduledoc """
  End-to-end integration tests for Phase 6b features: Memory and LLM.

  These tests compile Skein source code through the full pipeline
  (lex → parse → analyze → codegen → BEAM) and exercise the resulting
  modules against the runtime.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  setup do
    Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)
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
  # Module with Memory operations
  # ------------------------------------------------------------------

  describe "module with memory operations" do
    test "full memory lifecycle: put, get, delete, list" do
      mod =
        compile!("""
        module MemoryService {
          capability memory.kv("cache")

          fn store(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn fetch(key: String) -> String {
            memory.get(key)
          }

          fn remove(key: String) -> String {
            memory.delete(key)
          }

          fn all_keys(prefix: String) -> String {
            memory.list(prefix)
          }
        }
        """)

      Skein.Runtime.Memory.clear("cache")

      # Put values
      assert {:ok, "alice"} = mod.store("user:1", "alice")
      assert {:ok, "bob"} = mod.store("user:2", "bob")
      assert {:ok, "dark"} = mod.store("config:theme", "dark")

      # Get values
      assert {:ok, "alice"} = mod.fetch("user:1")
      assert {:error, :not_found} = mod.fetch("nonexistent")

      # List with prefix
      keys = mod.all_keys("user:")
      assert Enum.sort(keys) == ["user:1", "user:2"]

      # Delete
      assert {:ok, "user:1"} = mod.remove("user:1")
      assert {:error, :not_found} = mod.fetch("user:1")

      # List after delete
      keys = mod.all_keys("user:")
      assert keys == ["user:2"]

      Skein.Runtime.Memory.clear("cache")
    end
  end

  # ------------------------------------------------------------------
  # Module with LLM operations
  # ------------------------------------------------------------------

  describe "module with llm operations" do
    test "llm.chat returns response" do
      mod =
        compile!("""
        module AiChat {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(question: String) -> String {
            llm.chat("claude-sonnet-4-5", "You are a helpful assistant.", question)
          }
        }
        """)

      assert {:ok, response} = mod.ask("What is 2+2?")
      assert is_binary(response)
    end

    test "llm.json returns parsed map" do
      mod =
        compile!("""
        module AiJson {
          capability model("anthropic", "claude-sonnet-4-5")

          fn decide(ticket: String) -> String {
            llm.json("claude-sonnet-4-5", "Decide if this warrants a refund.", ticket)
          }
        }
        """)

      # Schemaless llm.json returns a (possibly empty) map under the test
      # backend, which now conforms to the requested schema rather than a
      # fixed canned shape (skein-testing #4).
      assert {:ok, result} = mod.decide("Ticket: item not received")
      assert is_map(result)
    end
  end

  # ------------------------------------------------------------------
  # Module with both Memory and LLM
  # ------------------------------------------------------------------

  describe "module with both memory and llm" do
    test "module compiles and uses both memory and llm" do
      mod =
        compile!("""
        module DecisionService {
          capability memory.kv("decisions")
          capability model("anthropic", "claude-sonnet-4-5")

          fn analyze(ticket: String) -> String {
            llm.chat("claude-sonnet-4-5", "Analyze this ticket.", ticket)
          }

          fn save_result(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn get_result(key: String) -> String {
            memory.get(key)
          }
        }
        """)

      Skein.Runtime.Memory.clear("decisions")

      # Use LLM
      assert {:ok, analysis} = mod.analyze("Customer wants refund")
      assert is_binary(analysis)

      # Store result in memory
      assert {:ok, _} = mod.save_result("ticket:1", "approved")

      # Retrieve from memory
      assert {:ok, "approved"} = mod.get_result("ticket:1")

      Skein.Runtime.Memory.clear("decisions")
    end
  end

  # ------------------------------------------------------------------
  # Tracing for Memory and LLM
  # ------------------------------------------------------------------

  describe "tracing" do
    test "memory and llm operations both produce trace spans" do
      mod =
        compile!("""
        module TracedService {
          capability memory.kv("traced")
          capability model("anthropic", "claude-sonnet-4-5")

          fn store(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn ask(question: String) -> String {
            llm.chat("claude-sonnet-4-5", "system", question)
          }
        }
        """)

      Skein.Runtime.Memory.clear("traced")

      mod.store("k", "v")
      mod.ask("hello")

      spans = Skein.Runtime.Trace.recent_spans(20)

      memory_spans = Enum.filter(spans, &(&1.kind == :memory))
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))

      assert length(memory_spans) >= 1
      assert length(llm_spans) >= 1

      mem_span = hd(memory_spans)
      assert mem_span.method == :put
      assert mem_span.namespace == "traced"
      assert is_integer(mem_span.duration_us)

      llm_span = hd(llm_spans)
      assert llm_span.method == :chat
      assert llm_span.model == "claude-sonnet-4-5"
      assert is_integer(llm_span.duration_us)

      Skein.Runtime.Memory.clear("traced")
    end
  end

  # ------------------------------------------------------------------
  # llm.json[T] — type-parameterized schema generation
  # ------------------------------------------------------------------

  describe "llm.json[T] with type parameter" do
    test "llm.json[T] compiles and passes schema derived from type T" do
      mod =
        compile!("""
        module AiTyped {
          type RefundDecision {
            action: String
            amount: Int
            reason: String
          }

          capability model("anthropic", "claude-sonnet-4-5")

          fn decide(ticket: String) -> String {
            llm.json[RefundDecision]("claude-sonnet-4-5", "Decide if this warrants a refund.", ticket)
          }
        }
        """)

      assert {:ok, result} = mod.decide("Ticket: item not received")
      assert is_map(result)
    end

    test "field access on an llm.json[T] result returns the field values (#154)" do
      mod =
        compile!("""
        module AiFieldAccess {
          capability model("anthropic", "claude-sonnet-4-5")

          type RefundDecision {
            action: String
            amount: Int
            reason: String
          }

          fn decide(ticket: String) -> String {
            let d = llm.json[RefundDecision]("claude-sonnet-4-5", "Decide.", ticket)!
            "${d.action}:${d.amount}"
          }
        }
        """)

      # A fixture backend returns a concrete string-keyed RefundDecision
      # like the real backends; schema-directed atomization makes d.action
      # and d.amount work end-to-end.
      Skein.Runtime.Llm.set_backend(Skein.Integration.MemoryLlmTest.RefundDecisionBackend)
      assert mod.decide("Ticket: item not received") == "approve:100"
    end

    test "spec 8.4 flow: agent matches on llm.json[T] result fields end-to-end (#154)" do
      {:module, mod} =
        Skein.Compiler.compile_string("""
        module RefundFlow {
          capability model("anthropic", "claude-sonnet-4-5")

          type RefundDecision {
            action: String
            amount: Int
            reason: String
          }

          agent Decider {
            enum Phase {
              Analyze -> [Refund, Done, Failed]
              Refund -> []
              Done -> []
              Failed -> [Analyze]
            }

            on start(ticket: String) -> {
              transition(Phase.Analyze)
            }

            on phase(Phase.Analyze) -> {
              let decision = llm.json[RefundDecision](
                model: "claude-sonnet-4-5",
                system: "Decide if this ticket warrants a refund. Return JSON.",
                input: "ticket"
              )

              match decision {
                Ok(d) -> {
                  match d.action {
                    "approve" -> transition(Phase.Refund)
                    "deny" -> transition(Phase.Done)
                    _ -> transition(Phase.Failed)
                  }
                }
                Err(_) -> transition(Phase.Failed)
              }
            }

            on phase(Phase.Refund) -> {
              stop()
            }

            on phase(Phase.Done) -> {
              stop()
            }

            on phase(Phase.Failed) -> {
              suspend("Requires human review")
            }
          }
        }
        """)

      agent_mod = Module.concat(["Skein", "Agent", "RefundFlow", "Decider"])

      # Fixture backend returns action "approve" so the phase handler takes
      # the Refund branch deterministically.
      Skein.Runtime.Llm.set_backend(Skein.Integration.MemoryLlmTest.RefundDecisionBackend)

      assert {:transition, :refund, _state, _events} =
               agent_mod.__phase_handler__(:analyze, %{}, [])

      # The module atom for the nested agent is returned alongside the
      # primary module; silence the unused-binding warning.
      _ = mod
    end

    test "llm.json without type parameter still works (backward compat)" do
      mod =
        compile!("""
        module AiUntyped {
          capability model("anthropic", "claude-sonnet-4-5")

          fn decide(ticket: String) -> String {
            llm.json("claude-sonnet-4-5", "Decide.", ticket)
          }
        }
        """)

      assert {:ok, result} = mod.decide("Ticket: item not received")
      assert is_map(result)
    end
  end

  # ------------------------------------------------------------------
  # Capability enforcement
  # ------------------------------------------------------------------

  describe "analyzer blocks undeclared capabilities" do
    test "memory calls without memory.kv are rejected at compile time" do
      source = """
      module NoCap {
        fn save(key: String, value: String) -> String {
          memory.put(key, value)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)
      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "memory.kv"))
    end

    test "llm calls without model capability are rejected at compile time" do
      source = """
      module NoCap {
        fn ask(data: String) -> String {
          llm.chat("claude-sonnet-4-5", "system", data)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)
      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "model"))
    end

    test "llm.stream calls without model capability are rejected at compile time" do
      source = """
      module NoCapStream {
        fn stream_it(data: String) -> String {
          llm.stream("claude-sonnet-4-5", "system", data)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)
      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "model"))
    end
  end

  # ------------------------------------------------------------------
  # LLM streaming integration (Phase 8f)
  # ------------------------------------------------------------------

  describe "llm.stream integration" do
    test "llm.stream compiles and runs end-to-end" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module StreamIntegration {
          capability model("anthropic", "claude-sonnet-4-5")

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "You are a helpful assistant.", data)
          }
        }
        """)

      assert {:ok, response} = mod.stream_it("Hello")
      assert is_binary(response)
    end

    test "llm.stream delivers each chunk to the on_chunk callback" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)
      Skein.Runtime.Memory.clear("chunks")

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module StreamCallback {
          capability model("anthropic", "claude-sonnet-4-5")
          capability memory.kv("chunks")

          fn record(chunk: String) -> String {
            memory.put(chunk, chunk)!
            chunk
          }

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "system", data, &record)
          }
        }
        """)

      assert {:ok, "Hello, world!"} = mod.stream_it("Hi")

      # StreamingTestBackend emits ["Hello, ", "world!"] — the callback
      # must observe every chunk, not a fabricated no-op.
      caps = [%{kind: "memory.kv", params: ["chunks"]}]
      assert {:ok, "Hello, "} = Skein.Runtime.Memory.get("chunks", "Hello, ", caps)
      assert {:ok, "world!"} = Skein.Runtime.Memory.get("chunks", "world!", caps)
    end

    test "llm.stream with a named on_chunk argument compiles and runs" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module StreamNamedCallback {
          capability model("anthropic", "claude-sonnet-4-5")

          fn record(chunk: String) -> String {
            chunk
          }

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "system", data, on_chunk: &record)
          }
        }
        """)

      assert {:ok, "Hello, world!"} = mod.stream_it("Hi")
    end

    test "llm.stream uses same model capability as chat and json" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module StreamCaps {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "system", data)
          }

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "system", data)
          }
        }
        """)

      # Both should work with the same capability
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)
      assert {:ok, _} = mod.ask("Hello")

      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)
      assert {:ok, _} = mod.stream_it("Hello")
    end
  end

  # ------------------------------------------------------------------
  # LLM embedding integration
  # ------------------------------------------------------------------

  describe "llm.embed integration" do
    test "llm.embed compiles and runs end-to-end" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module EmbedIntegration {
          capability model("anthropic", "text-embedding-3-small")

          fn get_embedding(text: String) -> String {
            llm.embed("text-embedding-3-small", text)
          }
        }
        """)

      assert {:ok, vector} = mod.get_embedding("Hello world")
      assert is_list(vector)
      assert Enum.all?(vector, &is_float/1)
    end

    test "llm.embed uses same model capability as chat" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} =
        Skein.Compiler.compile_string("""
        module EmbedCaps {
          capability model("anthropic", "text-embedding-3-small")

          fn ask(data: String) -> String {
            llm.chat("text-embedding-3-small", "system", data)
          }

          fn embed_it(text: String) -> String {
            llm.embed("text-embedding-3-small", text)
          }
        }
        """)

      assert {:ok, _} = mod.ask("Hello")
      assert {:ok, vector} = mod.embed_it("Hello")
      assert is_list(vector)
    end

    test "llm.embed without model capability is rejected at compile time" do
      source = """
      module NoCapEmbed {
        fn embed_it(text: String) -> String {
          llm.embed("text-embedding-3-small", text)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)
      assert Enum.any?(errors, &(&1.code == "E0012" and &1.message =~ "model"))
    end
  end
end

defmodule Skein.Integration.MemoryLlmTest.RefundDecisionBackend do
  @moduledoc false
  # A fixture LLM backend that returns a concrete RefundDecision, used by
  # the #154 field-access / agent-flow tests that need specific values
  # rather than the schema-conforming placeholders the default test
  # backend now produces.
  @behaviour Skein.Runtime.Llm.Backend

  @impl true
  def chat(_model, _system, _input), do: {:ok, ""}

  @impl true
  def json(_model, _system, _input, _schema) do
    {:ok, %{"action" => "approve", "amount" => 100, "reason" => "item not received"}}
  end
end
