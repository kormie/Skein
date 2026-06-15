defmodule Skein.NamedArgsTest do
  @moduledoc """
  Named arguments in calls: `f(name: value)`.

  Covers the parser (`AST.NamedArg` nodes), the analyzer rewrite pass
  (named args validated against parameter names and reordered into
  positional order), the E0026 error family, and end-to-end execution.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

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

  # Digs the first Call expression out of the body of the named fn.
  defp call_in_fn(%AST.Module{declarations: decls}, fn_name) do
    %AST.Fn{body: %AST.Block{expressions: exprs}} =
      Enum.find(decls, &match?(%AST.Fn{name: ^fn_name}, &1))

    Enum.find_value(exprs, fn
      %AST.Call{} = call -> call
      %AST.Let{value: %AST.Call{} = call} -> call
      _ -> nil
    end)
  end

  # ------------------------------------------------------------------
  # Parser
  # ------------------------------------------------------------------

  describe "parser" do
    test "parses a single named argument" do
      {:ok, ast} =
        parse("""
        module M {
          fn f(a: Int) -> Int { a }
          fn g() -> Int { f(a: 1) }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.NamedArg{name: "a", value: %AST.IntLit{value: 1}}] = call.args
    end

    test "parses positional followed by named arguments" do
      {:ok, ast} =
        parse("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(1, b: 2) }
        }
        """)

      call = call_in_fn(ast, "g")

      assert [
               %AST.IntLit{value: 1},
               %AST.NamedArg{name: "b", value: %AST.IntLit{value: 2}}
             ] = call.args
    end

    test "parses named arguments in an unwrapped call (bang)" do
      {:ok, ast} =
        parse("""
        module M {
          capability memory.kv("ns")
          fn g() -> String { memory.get!(key: "k") }
        }
        """)

      %AST.Fn{body: %AST.Block{expressions: [expr]}} =
        Enum.find(ast.declarations, &match?(%AST.Fn{name: "g"}, &1))

      assert %AST.UnaryOp{op: :unwrap, operand: %AST.Call{args: args}} = expr
      assert [%AST.NamedArg{name: "key"}] = args
    end

    test "parses named arguments in a type-parameterized call" do
      {:ok, ast} =
        parse("""
        module M {
          capability model("anthropic", "claude-opus-4-8")
          type T { action: String }
          fn g(ticket: String) -> String {
            llm.json[T](model: "claude-opus-4-8", system: "Decide.", input: ticket)
          }
        }
        """)

      call = call_in_fn(ast, "g")
      assert %AST.Call{type_param: %AST.TypeRef{name: "T"}} = call

      assert [
               %AST.NamedArg{name: "model"},
               %AST.NamedArg{name: "system"},
               %AST.NamedArg{name: "input"}
             ] = call.args
    end

    test "map literal arguments still parse as map literals" do
      {:ok, ast} =
        parse("""
        module M {
          fn f(m: Map) -> Map { m }
          fn g() -> Map { f({ a: 1 }) }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.MapLit{entries: [{"a", %AST.IntLit{value: 1}}]}] = call.args
    end

    test "named argument values can be arbitrary expressions" do
      {:ok, ast} =
        parse("""
        module M {
          fn f(a: Int) -> Int { a }
          fn g(x: Int) -> Int { f(a: x + 1) }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.NamedArg{name: "a", value: %AST.BinaryOp{op: :+}}] = call.args
    end
  end

  # ------------------------------------------------------------------
  # Analyzer: rewrite to positional order
  # ------------------------------------------------------------------

  describe "analyzer rewrite" do
    test "reorders named arguments into declared parameter order" do
      {:ok, ast} =
        analyze("""
        module M {
          fn f(a: Int, b: Int, c: Int) -> Int { a }
          fn g() -> Int { f(c: 3, a: 1, b: 2) }
        }
        """)

      call = call_in_fn(ast, "g")

      assert [
               %AST.IntLit{value: 1},
               %AST.IntLit{value: 2},
               %AST.IntLit{value: 3}
             ] = call.args
    end

    test "positional-then-named fills remaining parameters by name" do
      {:ok, ast} =
        analyze("""
        module M {
          fn f(a: Int, b: Int, c: Int) -> Int { a }
          fn g() -> Int { f(1, c: 3, b: 2) }
        }
        """)

      call = call_in_fn(ast, "g")

      assert [
               %AST.IntLit{value: 1},
               %AST.IntLit{value: 2},
               %AST.IntLit{value: 3}
             ] = call.args
    end

    test "effect call with named arguments analyzes and reorders" do
      {:ok, ast} =
        analyze("""
        module M {
          capability model("anthropic", "claude-opus-4-8")
          fn g(ticket: String) -> Result[String, String] {
            llm.chat(input: ticket, model: "claude-opus-4-8", system: "Analyze.")
          }
        }
        """)

      call = call_in_fn(ast, "g")

      assert [
               %AST.StringLit{},
               %AST.StringLit{},
               %AST.Identifier{name: "ticket"}
             ] = call.args
    end

    test "named arguments work in agent fns" do
      {:ok, _ast} =
        analyze("""
        agent A {
          capability memory.kv("ns")

          state {
            count: Int
          }

          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(b: 2, a: 1) }
        }
        """)
    end

    test "all-positional calls are untouched" do
      {:ok, ast} =
        analyze("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(1, 2) }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.IntLit{value: 1}, %AST.IntLit{value: 2}] = call.args
    end

    test "process.spawn by name may omit the optional work parameter" do
      {:ok, ast} =
        analyze("""
        module M {
          capability process.spawn("workers")
          fn g() -> Result[String, String] { process.spawn(task: "job") }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.StringLit{}] = call.args
    end

    test "process.spawn accepts the optional work parameter by name" do
      {:ok, ast} =
        analyze("""
        module M {
          capability process.spawn("workers")
          fn do_work() -> String { "done" }
          fn g() -> Result[String, String] { process.spawn(task: "job", work: &do_work) }
        }
        """)

      call = call_in_fn(ast, "g")
      assert [%AST.StringLit{}, %AST.FnRef{name: "do_work"}] = call.args
    end

    test "process.spawn with only work named is missing the required task" do
      errors =
        analyze_errors("""
        module M {
          capability process.spawn("workers")
          fn do_work() -> String { "done" }
          fn g() -> Result[String, String] { process.spawn(work: &do_work) }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0026" and &1.message =~ "task"))
    end

    test "process.spawn(name:) is unknown — the spec §6.11 parameter is 'task'" do
      errors =
        analyze_errors("""
        module M {
          capability process.spawn("workers")
          fn g() -> Result[String, String] { process.spawn(name: "job") }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0026" and &1.fix_code =~ "task"))
    end
  end

  # ------------------------------------------------------------------
  # Analyzer: E0026 errors
  # ------------------------------------------------------------------

  describe "analyzer errors" do
    test "positional argument after named argument is E0026" do
      errors =
        analyze_errors("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(a: 1, 2) }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0026" and e.message =~ "Positional argument"
             end)
    end

    test "unknown argument name is E0026 with valid names in the fix_hint" do
      errors =
        analyze_errors("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(a: 1, oops: 2) }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0026"))
      assert error
      assert error.message =~ "oops"
      assert error.fix_hint =~ "a"
      assert error.fix_hint =~ "b"
    end

    test "duplicate named argument is E0026" do
      errors =
        analyze_errors("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(a: 1, a: 2) }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0026" and e.message =~ "Duplicate"
             end)
    end

    test "naming a parameter already filled positionally is E0026" do
      errors =
        analyze_errors("""
        module M {
          fn f(a: Int, b: Int) -> Int { a }
          fn g() -> Int { f(1, a: 2) }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0026" and e.message =~ "'a'"
             end)
    end

    test "missing parameter in a named call is E0026" do
      errors =
        analyze_errors("""
        module M {
          fn f(a: Int, b: Int, c: Int) -> Int { a }
          fn g() -> Int { f(a: 1, c: 3) }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0026" and e.message =~ "'b'"
             end)
    end

    test "named arguments on a callee without a known signature is E0026" do
      errors =
        analyze_errors("""
        module M {
          fn g(s: String) -> Bool { String.contains(s, needle: "x") }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0026"))
      assert error
      assert error.message =~ "not supported"
      assert error.fix_hint =~ "positional"
    end

    test "unknown named argument on an effect call lists the effect's parameters" do
      errors =
        analyze_errors("""
        module M {
          capability model("anthropic", "claude-opus-4-8")
          fn g(t: String) -> Result[String, String] {
            llm.chat(model: "claude-opus-4-8", prompt: t, system: "x")
          }
        }
        """)

      error = Enum.find(errors, &(&1.code == "E0026"))
      assert error
      assert error.message =~ "prompt"
      assert error.fix_hint =~ "input"
    end

    test "named arguments are not allowed in match patterns" do
      {:ok, tokens} =
        Lexer.tokenize("""
        module M {
          enum Event {
            Charge(amount: Int)
          }

          fn g(e: Event) -> Int {
            match e {
              Event.Charge(amount: 5) -> 5
              _ -> 0
            }
          }
        }
        """)

      assert {:error, _errors} = Parser.parse(tokens)
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

    test "named arguments are passed in declared order at runtime" do
      mod =
        compile!("""
        module NamedOrder {
          fn describe(name: String, suffix: String) -> String {
            "${name}:${suffix}"
          }

          fn flipped() -> String {
            describe(suffix: "three", name: "widget")
          }

          fn mixed() -> String {
            describe("gadget", suffix: "seven")
          }
        }
        """)

      assert mod.flipped() == "widget:three"
      assert mod.mixed() == "gadget:seven"
    end

    test "llm.chat with named arguments compiles and runs" do
      mod =
        compile!("""
        module NamedLlm {
          capability model("anthropic", "claude-opus-4-8")

          fn ask(question: String) -> Result[String, String] {
            llm.chat(model: "claude-opus-4-8", system: "You are helpful.", input: question)
          }
        }
        """)

      assert {:ok, response} = mod.ask("What is 2+2?")
      assert is_binary(response)
    end

    test "memory effects with named arguments compile and run" do
      mod =
        compile!("""
        module NamedMemory {
          capability memory.kv("named_args_test")

          fn save(k: String, v: String) -> Result[String, String] {
            memory.put(key: k, value: v)
          }

          fn load(k: String) -> Result[String, String] {
            memory.get(key: k)
          }
        }
        """)

      Skein.Runtime.Memory.clear("named_args_test")
      assert {:ok, _} = mod.save("greeting", "hello")
      assert {:ok, "hello"} = mod.load("greeting")
    end
  end

  # ------------------------------------------------------------------
  # Property: any permutation of named args resolves to declared order
  # ------------------------------------------------------------------

  @param_names ~w(z_a z_b z_c z_d)

  property "named arguments in any order resolve to declared positional order" do
    check all(
            arity <- StreamData.integer(1..4),
            sort_keys <- StreamData.list_of(StreamData.integer(), length: arity)
          ) do
      # A permutation of 0..arity-1 derived from random sort keys
      # (index breaks ties, so every key list yields a valid permutation).
      order = Enum.sort_by(0..(arity - 1), fn i -> {Enum.at(sort_keys, i), i} end)
      params = Enum.take(@param_names, arity)
      param_list = Enum.map_join(params, ", ", &"#{&1}: Int")
      named_args = Enum.map_join(order, ", ", fn i -> "#{Enum.at(params, i)}: #{i}" end)

      {:ok, ast} =
        analyze("""
        module P {
          fn target(#{param_list}) -> Int { #{hd(params)} }
          fn caller() -> Int { target(#{named_args}) }
        }
        """)

      call = call_in_fn(ast, "caller")
      assert Enum.map(call.args, & &1.value) == Enum.to_list(0..(arity - 1))
    end
  end
end
