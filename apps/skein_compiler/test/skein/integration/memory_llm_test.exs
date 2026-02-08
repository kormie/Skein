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
      assert {:error, "not_found"} = mod.fetch("nonexistent")

      # List with prefix
      keys = mod.all_keys("user:")
      assert Enum.sort(keys) == ["user:1", "user:2"]

      # Delete
      assert {:ok, "user:1"} = mod.remove("user:1")
      assert {:error, "not_found"} = mod.fetch("user:1")

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

      assert {:ok, result} = mod.decide("Ticket: item not received")
      assert is_map(result)
      assert Map.has_key?(result, "action")
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
      assert Enum.any?(errors, &(&1.code == "E0030" and &1.message =~ "memory.kv"))
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
      assert Enum.any?(errors, &(&1.code == "E0030" and &1.message =~ "model"))
    end
  end
end
