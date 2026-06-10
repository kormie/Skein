defmodule Skein.AnalyzerFixCodeTest do
  @moduledoc """
  Structured-error contract sweep for the analyzer.

  CLAUDE.md design constraint #5: every compiler error must carry both
  `fix_hint` and `fix_code`. Each bad program below triggers a different
  analyzer error path; the sweep asserts the contract holds for every
  error and warning produced.
  """
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  defp analyze_errors(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:error, errors} -> errors
      {:ok, _, warnings} -> warnings
      {:ok, _} -> []
    end
  end

  # Each entry: {description, source} — every error the source produces
  # must carry fix_hint and fix_code.
  @bad_programs [
    {"E0024 unknown type",
     """
     module M {
       fn f(x: Strang) -> String { "x" }
     }
     """},
    {"E0025 @min on non-numeric",
     """
     module M {
       type T {
         name: String @min(1)
       }
     }
     """},
    {"E0025 @one_of on non-string",
     """
     module M {
       type T {
         count: Int @one_of(["a", "b"])
       }
     }
     """},
    {"E0020 return type mismatch",
     """
     module M {
       fn f() -> Int { "hello" }
     }
     """},
    {"E0020 arithmetic on strings",
     """
     module M {
       fn f() -> Int { "a" * "b" }
     }
     """},
    {"E0020 ordering comparison on mixed types",
     """
     module M {
       fn f() -> Bool { 1 < "a" }
     }
     """},
    {"E0020 logical op on non-bool",
     """
     module M {
       fn f() -> Bool { 1 && true }
     }
     """},
    {"E0020 not on non-bool",
     """
     module M {
       fn f() -> Bool { !"hello" && true }
     }
     """},
    {"E0010 unknown identifier",
     """
     module M {
       fn f() -> Int { undeclared_var }
     }
     """},
    {"E0010 unknown identifier in interpolation",
     """
     module M {
       fn f() -> String { "value: ${missing}" }
     }
     """},
    {"E0020 wrong arity local call",
     """
     module M {
       fn g(a: Int, b: Int) -> Int { a + b }
       fn f() -> Int { g(1) }
     }
     """},
    {"E0010 unknown stdlib function",
     """
     module M {
       fn f() -> String { String.upcase_all("x") }
     }
     """},
    {"E0020 stdlib wrong arity",
     """
     module M {
       fn f() -> String { String.trim("a", "b", "c") }
     }
     """},
    {"E0020 stdlib argument type mismatch",
     """
     module M {
       fn f() -> Int { String.length(42) }
     }
     """},
    {"E0020 unknown field on type",
     """
     module M {
       type User {
         name: String
       }
       fn f(u: User) -> String { u.email }
     }
     """},
    {"E0020 field access on builtin",
     """
     module M {
       fn f(s: String) -> String { s.name }
     }
     """},
    {"E0021 non-exhaustive bool match",
     """
     module M {
       fn f(b: Bool) -> Int {
         match b {
           true -> 1
         }
       }
     }
     """},
    {"E0020 match arm type mismatch",
     """
     module M {
       fn f(b: Bool) -> Int {
         match b {
           true -> 1
           false -> "nope"
         }
       }
     }
     """},
    {"E0011 duplicate definition",
     """
     module M {
       fn f() -> Int { 1 }
       fn f() -> Int { 2 }
     }
     """},
    {"W0001 unused binding",
     """
     module M {
       fn f() -> Int {
         let unused = 42
         1
       }
     }
     """},
    {"W0002 unused capability",
     """
     module M {
       capability http.out

       fn f() -> Int { 1 }
     }
     """},
    {"E0042 supervisor with no children",
     """
     module M {
       supervisor Pool {
         strategy: one_for_one
       }
     }
     """},
    {"E0035 idempotent outside handler",
     """
     module M {
       fn f() -> Int {
         idempotent("key")
         1
       }
     }
     """}
  ]

  @agent_programs [
    {"E0030 transition to unknown phase",
     """
     agent A {
       enum Phase {
         Start -> [Done]
         Done -> []
       }

       on start(id: String) -> {
         transition(Phase.Start)
       }

       on phase(Phase.Start) -> {
         transition(Phase.Missing)
       }

       on phase(Phase.Done) -> {
         stop()
       }
     }
     """},
    {"E0030 disallowed transition",
     """
     agent A {
       enum Phase {
         Start -> [Done]
         Done -> []
       }

       on start(id: String) -> {
         transition(Phase.Start)
       }

       on phase(Phase.Start) -> {
         transition(Phase.Done)
       }

       on phase(Phase.Done) -> {
         transition(Phase.Start)
       }
     }
     """},
    {"W0003 unreachable code after stop",
     """
     agent A {
       enum Phase {
         Start -> []
       }

       on start(id: String) -> {
         transition(Phase.Start)
       }

       on phase(Phase.Start) -> {
         stop()
         transition(Phase.Start)
       }
     }
     """}
  ]

  # The parser whitelists strategy names, so an invalid strategy can only
  # reach the analyzer through a constructed AST.
  test "E0040 invalid supervisor strategy: error carries fix_hint and fix_code" do
    meta = %{line: 1, col: 1, file: "test"}

    supervisor = %Skein.AST.Supervisor{
      name: "Pool",
      children: [%Skein.AST.Child{target: "Worker", args: [], options: [], meta: meta}],
      strategy: :round_robin,
      max_restarts: nil,
      meta: meta
    }

    module = %Skein.AST.Module{
      name: "M",
      capabilities: [],
      declarations: [supervisor],
      meta: meta
    }

    assert {:error, errors} = Analyzer.analyze(module)
    assert [%{code: "E0040"} = error] = errors
    assert error.fix_hint != nil
    assert error.fix_code == "strategy: one_for_one"
  end

  for {description, source} <- @bad_programs ++ @agent_programs do
    test "#{description}: every error carries fix_hint and fix_code" do
      errors = analyze_errors(unquote(source))

      assert errors != [], "expected at least one error/warning from this program"

      for error <- errors do
        assert error.fix_hint != nil,
               "#{error.code} '#{error.message}' is missing fix_hint"

        assert error.fix_code != nil,
               "#{error.code} '#{error.message}' is missing fix_code"
      end
    end
  end
end
