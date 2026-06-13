defmodule Skein.NestedAgentTest do
  @moduledoc """
  Agents nested inside modules: `module Foo { agent Bar { ... } }`.

  Covers parsing (`AST.Agent` as a module declaration), analysis (module
  types and capabilities visible to the nested agent), codegen (the agent
  compiles to its own namespaced BEAM module, `Skein.Agent.Foo.Bar`), and
  end-to-end execution of nested agent handlers.
  """
  use ExUnit.Case, async: false

  # These agent modules are generated and loaded at test runtime by the
  # Skein compiler — they don't exist when this file is compiled. The
  # directive scopes the undefined-module warning exception to exactly
  # these names; any other undefined reference still warns.
  @compile {:no_warn_undefined, Skein.Agent.Orders.OrderAgent}
  @compile {:no_warn_undefined, Skein.Agent.Refunds.RefundAgent}
  @compile {:no_warn_undefined, Skein.Agent.M.A}

  alias Skein.AST
  alias Skein.Analyzer
  alias Skein.Compiler
  alias Skein.Lexer
  alias Skein.Parser

  defp parse(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Parser.parse(tokens)
  end

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  defp analyze_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:error, errors} -> errors
      {:ok, _, warnings} -> warnings
      {:ok, _} -> []
    end
  end

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  @nested_source """
  module Orders {
    capability memory.kv("orders")

    agent OrderAgent {
      state {
        order_id: String
      }

      enum Phase {
        Pending -> [Done]
        Done    -> []
      }

      on start(order_id: String) -> {
        memory.put("order_id", order_id)
        transition(Phase.Pending)
      }

      on phase(Phase.Pending) -> {
        transition(Phase.Done)
      }

      on phase(Phase.Done) -> {
        stop()
      }
    }
  }
  """

  # ------------------------------------------------------------------
  # Parser
  # ------------------------------------------------------------------

  describe "parser" do
    test "agent is accepted as a module declaration" do
      {:ok, ast} = parse(@nested_source)

      assert %AST.Module{name: "Orders", declarations: decls} = ast

      assert %AST.Agent{name: "OrderAgent", handlers: handlers} =
               Enum.find(decls, &match?(%AST.Agent{}, &1))

      assert length(handlers) == 3
    end

    test "module can mix agents with fns, types, and tools" do
      {:ok, ast} =
        parse("""
        module Mixed {
          type Decision { action: String }

          fn helper(x: Int) -> Int { x }

          agent Worker {
            state { n: Int }
            enum Phase { Only -> [] }
            on start(n: Int) -> { transition(Phase.Only) }
            on phase(Phase.Only) -> { stop() }
          }
        }
        """)

      assert Enum.any?(ast.declarations, &match?(%AST.TypeDecl{}, &1))
      assert Enum.any?(ast.declarations, &match?(%AST.Fn{}, &1))
      assert Enum.any?(ast.declarations, &match?(%AST.Agent{name: "Worker"}, &1))
    end
  end

  # ------------------------------------------------------------------
  # Analyzer
  # ------------------------------------------------------------------

  describe "analyzer" do
    test "a valid nested agent analyzes cleanly" do
      assert {:ok, _ast} = analyze(@nested_source)
    end

    test "invalid transition inside a nested agent is caught (E0030)" do
      errors =
        analyze_errors("""
        module M {
          agent A {
            state { x: Int }
            enum Phase {
              First -> [Second]
              Second -> []
            }
            on start(x: Int) -> { transition(Phase.First) }
            on phase(Phase.First) -> { transition(Phase.Second) }
            on phase(Phase.Second) -> { transition(Phase.First) }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0030"))
    end

    test "module-level capability covers nested agent effects" do
      # memory.kv is declared on the module, not the agent — no E0012.
      errors = analyze_errors(@nested_source)
      refute Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "missing capability inside a nested agent is still E0012" do
      errors =
        analyze_errors("""
        module M {
          agent A {
            state { x: Int }
            enum Phase { Only -> [] }
            on start(x: Int) -> {
              memory.put("k", "v")
              transition(Phase.Only)
            }
            on phase(Phase.Only) -> { stop() }
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0012"))
    end

    test "module-level capability used only by the nested agent is not W0002" do
      errors = analyze_errors(@nested_source)
      refute Enum.any?(errors, &(&1.code == "W0002"))
    end

    test "module-level types are usable from the nested agent" do
      assert {:ok, _} =
               analyze("""
               module Refunds {
                 capability model("anthropic", "claude-opus-4-8")

                 type Decision {
                   action: String
                 }

                 agent RefundAgent {
                   state { ticket: String }
                   enum Phase {
                     Analyze -> [Done]
                     Done -> []
                   }
                   on start(ticket: String) -> { transition(Phase.Analyze) }
                   on phase(Phase.Analyze) -> {
                     let decision = llm.json[Decision](
                       model: "claude-opus-4-8",
                       system: "Decide.",
                       input: "ticket"
                     )
                     transition(Phase.Done)
                   }
                   on phase(Phase.Done) -> { stop() }
                 }
               }
               """)
    end

    test "named arguments resolve against nested agent fns" do
      assert {:ok, _} =
               analyze("""
               module M {
                 agent A {
                   state { x: Int }
                   enum Phase { Only -> [] }

                   fn combine(a: Int, b: Int) -> Int { a + b }

                   on start(x: Int) -> { transition(Phase.Only) }
                   on phase(Phase.Only) -> {
                     let r = combine(b: 2, a: 1)
                     stop()
                   }
                 }
               }
               """)
    end
  end

  # ------------------------------------------------------------------
  # Integration: compile and run
  # ------------------------------------------------------------------

  describe "integration" do
    setup do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)
      :ok
    end

    test "nested agent compiles to a namespaced module alongside its parent" do
      mod = compile!(@nested_source)
      assert mod == Skein.User.Orders

      agent_mod = Skein.Agent.Orders.OrderAgent
      assert Code.ensure_loaded?(agent_mod)

      phase_names = agent_mod.__phases__() |> Enum.map(& &1.name) |> Enum.sort()
      assert phase_names == [:done, :pending]
    end

    test "nested agent handlers execute" do
      compile!(@nested_source)
      agent_mod = Skein.Agent.Orders.OrderAgent

      assert {:transition, :done, %{}, []} = agent_mod.__phase_handler__(:pending, %{}, [])
      assert {:stop, %{}, []} = agent_mod.__phase_handler__(:done, %{}, [])
    end

    test "module-level capability is honored by nested agent effects at runtime" do
      compile!(@nested_source)
      agent_mod = Skein.Agent.Orders.OrderAgent

      Skein.Runtime.Memory.clear("orders")
      # on start writes through the module-declared memory.kv capability
      assert {:transition, :pending, _state, _events} =
               agent_mod.__start_handler__(%{order_id: "ord-1"}, %{})
    end

    test "llm.json with a module-level type runs inside a nested agent handler" do
      compile!("""
      module Refunds {
        capability model("anthropic", "claude-opus-4-8")

        type Decision {
          action: String
        }

        agent RefundAgent {
          state { ticket: String }
          enum Phase {
            Analyze -> [Done]
            Done -> []
          }
          on start(ticket: String) -> { transition(Phase.Analyze) }
          on phase(Phase.Analyze) -> {
            let decision = llm.json[Decision](
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

      agent_mod = Skein.Agent.Refunds.RefundAgent

      # The ! unwrap would crash this handler if llm.json failed — reaching
      # the transition proves the schema-typed call executed end-to-end.
      assert {:transition, :done, _state, _events} =
               agent_mod.__phase_handler__(:analyze, %{}, [])
    end

    test "an agent phase handler can call a module-level fn (#8)" do
      # Regression for skein-testing#8: a module-level fn called from a
      # nested agent's phase handler used to lower to an unbound variable
      # and crash core_lint. Module fns are now inherited as local
      # functions of the agent's compiled module.
      mod =
        compile!("""
        module M {
          fn double(n: Int) -> Int { n * 2 }

          agent A {
            state { d: Int }
            enum Phase { Go -> [] }
            on start(n: Int) -> { transition(Phase.Go) }
            on phase(Phase.Go) -> {
              let d = double(21)
              stop()
            }
          }
        }
        """)

      assert mod == Skein.User.M

      agent_mod = Skein.Agent.M.A

      # The inherited fn is callable directly on the agent module...
      assert agent_mod.double(21) == 42

      # ...and resolves inside the phase handler (which used to crash
      # core_lint with an unbound variable for the call).
      assert {:stop, _state, _events} = agent_mod.__phase_handler__(:go, %{}, [])
    end

    test "top-level agents still compile unchanged" do
      mod =
        compile!("""
        agent Standalone {
          state { x: Int }
          enum Phase { Only -> [] }
          on start(x: Int) -> { transition(Phase.Only) }
          on phase(Phase.Only) -> { stop() }
        }
        """)

      assert mod == Skein.Agent.Standalone
      assert {:stop, %{}, []} = mod.__phase_handler__(:only, %{}, [])
    end
  end
end
