defmodule Skein.ErrorSpanTest do
  @moduledoc """
  Contract sweep for machine-applicable fixes (issue #150).

  Every error/warning the compiler emits is checked against the span +
  edit_kind invariants, and every code that promises a machine-applicable
  fix is pinned by actually APPLYING the fix (via the reference
  `Skein.Error.Edit` implementation) and asserting the error disappears
  on recompile.
  """
  use ExUnit.Case, async: true

  alias Skein.Error

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Full pipeline: returns every diagnostic the source produces at its
  # first failing stage (mirroring Compiler.check_file's collection).
  defp diagnostics(source) do
    case Skein.Lexer.tokenize(source) do
      {:error, errors} ->
        errors

      {:ok, tokens} ->
        case Skein.Parser.parse(tokens) do
          {:error, errors} ->
            errors

          {:ok, ast} ->
            case Skein.Analyzer.analyze(ast) do
              {:error, errors} -> errors
              {:ok, _, warnings} -> warnings
              {:ok, _} -> []
            end
        end
    end
  end

  defp assert_invariants(%Error{} = error, label) do
    if error.span do
      %{start: %{line: start_line, col: start_col}, end: %{line: end_line, col: end_col}} =
        error.span

      assert is_integer(start_line) and start_line >= 1, "#{label}: span start line"
      assert is_integer(start_col) and start_col >= 1, "#{label}: span start col"

      assert {end_line, end_col} >= {start_line, start_col},
             "#{label}: span end before start"
    end

    if error.edit_kind do
      assert error.edit_kind in Error.edit_kinds(),
             "#{label}: unknown edit_kind #{inspect(error.edit_kind)}"

      assert error.span != nil,
             "#{label}: edit_kind #{error.edit_kind} requires a span"

      unless error.edit_kind == :delete_line do
        assert is_binary(error.fix_code),
               "#{label}: edit_kind #{error.edit_kind} requires a fix_code"
      end
    end

    # The struct (including span/edit_kind) must survive JSON encoding
    assert {:ok, _} = Jason.decode(Error.to_json(error)), "#{label}: JSON round-trip"
  end

  # ------------------------------------------------------------------
  # Corpus: one program per error family (machine-applicable or not),
  # swept for the global invariants.
  # ------------------------------------------------------------------

  @corpus [
    {"lexer unexpected character", "module M { fn f() -> Int { 1 } }\n~"},
    {"lexer semicolon", "module M { fn f() -> Int { 1; } }"},
    {"lexer unterminated string", ~S|module M { fn f() -> String { "oops|},
    {"lexer unterminated interpolation", ~S|module M { fn f() -> String { "${name |},
    {"lexer expression interpolation", ~S|module M { fn f() -> String { "${a + b}" } }|},
    {"lexer empty interpolation", ~S|module M { fn f() -> String { "${}" } }|},
    {"lexer float underscore", "module M { fn f() -> Float { 1_000.5 } }"},
    {"parser missing token after keyword",
     """
     module M {
       tool Acme.Do {
         description "x"
       }
     }
     """},
    {"parser expected token", "module M { fn f() -> Int 42 }"},
    {"parser expected identifier", "module M { fn f(: Int) -> Int { 1 } }"},
    {"parser unexpected eof", "module M { fn f() -> Int {"},
    {"analyzer unknown type", "module M { fn f(x: Strng) -> String { x } }"},
    {"analyzer unknown identifier with suggestion",
     """
     module M {
       fn f(amount: Int) -> Int {
         amout
       }
     }
     """},
    {"analyzer unknown identifier without suggestion", "module M { fn f() -> Int { zzz_qqq } }"},
    {"analyzer unknown constructor",
     """
     module M {
       enum Status {
         Active -> []
       }

       fn f() -> Status { Activ() }
     }
     """},
    {"analyzer missing capability (effect)",
     """
     module M {
       fn f() -> String {
         http.get("https://example.com")!
       }
     }
     """},
    {"analyzer missing capability (store)",
     """
     module M {
       type User { id: String }

       fn f(u: User) -> User {
         store.users.put(u)!
       }
     }
     """},
    {"analyzer missing capability (tool)",
     """
     module M {
       fn f() -> String {
         tool.call(Acme.Do, {})!
       }
     }
     """},
    {"analyzer undeclared tool (E0014)",
     """
     module M {
       capability tool.use(Acme.Other)

       fn f() -> String {
         tool.call(Acme.Do, {})!
       }
     }
     """},
    {"analyzer unused binding",
     """
     module M {
       fn f() -> String {
         let unused = 1
         "ok"
       }
     }
     """},
    {"analyzer unused capability",
     """
     module M {
       capability timer("maintenance")

       fn f() -> String { "ok" }
     }
     """},
    {"analyzer type mismatch", "module M { fn f() -> Int { \"nope\" } }"},
    {"analyzer non-bool guard",
     """
     module M {
       fn f(x: Int) -> Int {
         match x {
           n if n + 1 -> n
           _ -> 0
         }
       }
     }
     """},
    {"analyzer invalid transition",
     """
     agent A {
       enum Phase {
         Working -> []
       }

       on start() -> {
         transition(Phase.Working)
       }

       on phase(Phase.Working) -> {
         transition(Phase.Working)
       }
     }
     """}
  ]

  describe "span/edit_kind invariants" do
    test "hold for every diagnostic in the corpus" do
      for {label, source} <- @corpus do
        errors = diagnostics(source)
        assert errors != [], "#{label}: expected diagnostics, got none"
        Enum.each(errors, &assert_invariants(&1, label))
      end
    end
  end

  # ------------------------------------------------------------------
  # Machine-applicable codes: span + edit_kind REQUIRED, and applying
  # the fix resolves the error.
  # ------------------------------------------------------------------

  # {label, source, code that must be machine-applicable}
  @machine_applicable [
    {"E0001 unexpected character", "module M { fn f() -> Int { 1 } }\n~", "E0001"},
    {"E0001 semicolon", "module M { fn f() -> Int { 1; } }", "E0001"},
    {"E0002 unterminated string", ~S|module M { fn f() -> String { "oops } }|, "E0002"},
    {"E0002 unterminated interpolation", ~S|module M { fn f(name: String) -> String { "${name |,
     "E0002"},
    {"E0003 float underscore", "module M { fn f() -> Float { 1_000.5 } }", "E0003"},
    {"E0001 missing token after keyword",
     """
     module M {
       tool Acme.Do {
         description "x"
         input { x: Int }
         output { y: Int }
         implement { { y: input.x } }
       }
     }
     """, "E0001"},
    {"E0001 expected token", "module M { fn f() -> Int 42 }\n}", "E0001"},
    {"E0010 unknown identifier with close binding",
     """
     module M {
       fn f(amount: Int) -> Int {
         amout
       }
     }
     """, "E0010"},
    {"E0010 unknown constructor",
     """
     module M {
       enum Status {
         Active -> []
       }

       fn f() -> Status { Activ() }
     }
     """, "E0010"},
    {"E0024 unknown type with suggestion",
     """
     module M {
       type Profile { id: String }

       fn f(x: Profil) -> String { "x" }
     }
     """, "E0024"},
    {"E0012 missing effect capability",
     """
     module M {
       fn f() -> String {
         http.get("https://example.com")!
       }
     }
     """, "E0012"},
    {"E0012 missing capability with existing capability line",
     """
     module M {
       capability event.log("audit")

       fn f() -> String {
         event.log("a", "b")
         http.get("https://example.com")!
       }
     }
     """, "E0012"},
    {"E0014 undeclared tool",
     """
     module M {
       capability tool.use(Acme.Other)

       fn f() -> String {
         tool.call(Acme.Other, {})!
         tool.call(Acme.Do, {})!
       }
     }
     """, "E0014"},
    {"W0001 unused binding",
     """
     module M {
       fn f() -> String {
         let unused = 1
         "ok"
       }
     }
     """, "W0001"},
    {"W0002 unused capability",
     """
     module M {
       capability timer("maintenance")

       fn f() -> String { "ok" }
     }
     """, "W0002"}
  ]

  describe "machine-applicable fixes" do
    test "every promised code carries span + edit_kind" do
      for {label, source, code} <- @machine_applicable do
        errors = Enum.filter(diagnostics(source), &(&1.code == code))
        assert errors != [], "#{label}: no #{code} produced"

        assert Enum.any?(errors, &(&1.span && &1.edit_kind)),
               "#{label}: no #{code} carries span + edit_kind"
      end
    end

    test "applying the fix resolves the error" do
      for {label, source, code} <- @machine_applicable do
        error =
          source
          |> diagnostics()
          |> Enum.find(&((&1.code == code and &1.span) && &1.edit_kind))

        assert error, "#{label}: no applicable #{code} found"

        assert {:ok, fixed_source} = Skein.Error.Edit.apply_fix(source, error),
               "#{label}: fix not applicable"

        remaining =
          fixed_source
          |> diagnostics()
          |> Enum.filter(&(&1.code == code and &1.message == error.message))

        assert remaining == [],
               "#{label}: error survived its own fix.\n--- fixed source ---\n#{fixed_source}"
      end
    end
  end
end
