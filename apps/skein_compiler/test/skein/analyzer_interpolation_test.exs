defmodule Skein.AnalyzerInterpolationTest do
  @moduledoc """
  Interpolation segment typing (#310): `${...}` renders exactly the scalar
  types with one canonical text rendering — String, Int, Float, Bool, Uuid,
  Instant (plus the sanctioned `:dynamic` seam). Everything else is E0020 at
  the segment with a conversion hint. Before this, any record/map/list/
  fn-ref/Option/Result segment compiled, loaded, and crashed at runtime with
  `{:unsupported_interpolation, value}` — and a Duration or enum segment
  silently rendered its leaked runtime representation.

  The "allowed" tests double as the drift pin against codegen's coercion
  whitelist: they compile AND RUN, so an allowed type that stops coercing
  fails here, not in production.
  """
  use ExUnit.Case, async: true

  alias Skein.Compiler

  defp errors(source) do
    case Compiler.compile_string(source) do
      {:module, _} -> []
      {:error, errs} -> errs
    end
  end

  defp interpolation_errors(source) do
    source |> errors() |> Enum.filter(&(&1.code == "E0020" and &1.message =~ "interpolat"))
  end

  describe "rejected segment types (E0020)" do
    test "a fn reference value" do
      errs =
        interpolation_errors("""
        module M {
          fn g() -> Int { 1 }
          fn f() -> String {
            let h = &g
            "value: ${h}"
          }
        }
        """)

      assert [_ | _] = errs
    end

    test "a bare fn name (previously a codegen invariant crash)" do
      errs =
        errors("""
        module M {
          fn greet() -> String { "hi" }
          fn f() -> String { "${greet}" }
        }
        """)

      assert Enum.any?(errs, &(&1.code == "E0020"))
      refute Enum.any?(errs, &(&1.message =~ "Core Erlang compilation failed"))
    end

    test "a record value" do
      errs =
        interpolation_errors("""
        module M {
          type User { name: String }
          fn f() -> String {
            let u = User { name: "a" }
            "user: ${u}"
          }
        }
        """)

      assert [_ | _] = errs
    end

    test "a map value" do
      errs =
        interpolation_errors("""
        module M {
          fn f() -> String {
            let m = { a: 1 }
            "map: ${m}"
          }
        }
        """)

      assert [_ | _] = errs
    end

    test "a list value" do
      errs =
        interpolation_errors("""
        module M {
          fn f() -> String {
            let l = [1, 2]
            "list: ${l}"
          }
        }
        """)

      assert [_ | _] = errs
    end

    test "an Option field, with a match hint" do
      errs =
        interpolation_errors("""
        module M {
          type User {
            name: String
            nickname: Option[String]
          }
          fn f(u: User) -> String {
            "nick: ${u.nickname}"
          }
        }
        """)

      assert Enum.any?(errs, &(&1.fix_hint =~ "Match"))
    end

    test "an unwrapped Result, with an unwrap hint" do
      errs =
        interpolation_errors("""
        module M {
          fn half(n: Int) -> Result[Int, String] { Ok(n / 2) }
          fn f() -> String {
            let r = half(4)
            "half: ${r}"
          }
        }
        """)

      assert Enum.any?(errs, &(&1.fix_hint =~ "!"))
    end

    test "an enum value (its runtime atom leaks the lowered name)" do
      errs =
        interpolation_errors("""
        module M {
          enum Status { Active Idle }
          fn f() -> String {
            let s = Status.Active
            "status: ${s}"
          }
        }
        """)

      assert [_ | _] = errs
    end

    test "a Duration (its runtime value is a bare number), with a to_string hint" do
      errs =
        interpolation_errors("""
        module M {
          fn f() -> String {
            let d = Duration.minutes(5)
            "took: ${d}"
          }
        }
        """)

      assert Enum.any?(errs, &(&1.fix_hint =~ "Duration.to_string"))
    end
  end

  describe "allowed segment types compile AND run (codegen whitelist drift pin)" do
    test "String, Int, Float, and Bool segments render" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module M {
                 fn f(s: String, n: Int, x: Float, b: Bool) -> String {
                   "${s} ${n} ${x} ${b}"
                 }
               }
               """)

      assert mod.f("a", 1, 1.5, true) == "a 1 1.5 true"
    end

    test "Uuid and Instant segments render their canonical strings" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module M {
                 fn f() -> String {
                   let id = Uuid.parse("00000000-0000-4000-8000-000000000001")!
                   let at = Instant.parse("2026-01-01T00:00:00Z")!
                   "${id} at ${at}"
                 }
               }
               """)

      rendered = mod.f()
      assert rendered =~ "00000000-0000-4000-8000-000000000001"
      assert rendered =~ "2026-01-01T00:00:00Z"
    end

    test "a dynamic-typed segment stays allowed (sanctioned seam)" do
      assert {:module, _} =
               Compiler.compile_string("""
               module M {
                 capability memory.kv
                 fn f() -> String {
                   let v = memory.get!("k")
                   "value: ${v}"
                 }
               }
               """)
    end

    test "field access on a record still type-checks the segment" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module M {
                 type User { name: String }
                 fn f() -> String {
                   let u = User { name: "ada" }
                   "hi ${u.name}"
                 }
               }
               """)

      assert mod.f() == "hi ada"
    end
  end
end
