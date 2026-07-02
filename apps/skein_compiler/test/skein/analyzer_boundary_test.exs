defmodule Skein.AnalyzerBoundaryTest do
  @moduledoc """
  Public-boundary soundness for `:unknown` and `Json` (#291 / B2).

  `:unknown` is an internal inference state. It must never cross a declared
  (annotated/public) boundary as if it were a real type, and a detected
  incompatibility between branches must not silently widen through a declared
  boundary. `Json` is a concrete type: any value may flow *into* a
  Json-typed position, but a Json value cannot flow into a concrete type
  without an explicit conversion.
  """
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)

    case Analyzer.analyze(ast) do
      {:ok, analyzed_ast, _warnings} -> {:ok, analyzed_ast}
      other -> other
    end
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  describe "E0037 — :unknown rejected at declared fn-return boundary" do
    test "top-level :unknown returned where a concrete type is declared" do
      # An unresolved bare call errors at the site (E0010, B4/#293) AND its
      # :unknown value is rejected at the declared boundary — the guard stays
      # even when the producer is separately diagnosed.
      errors =
        analyze_errors("""
        module M {
          fn get_base() -> Int {
            mystery()!
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0010"))
      assert [%Skein.Error{} = error] = Enum.filter(errors, &(&1.code == "E0037"))
      assert error.severity == :error
      assert error.message =~ "Int"
      assert error.message =~ "cannot be verified"
      assert error.fix_hint != nil
      assert error.fix_code != nil
    end

    test "the sanctioned dynamic seam (untyped store/memory payloads) still crosses" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("cache")

                 fn read_count() -> Int {
                   memory.get!("count")
                 }
               }
               """)
    end

    test "incompatible Result error components do not widen through the boundary" do
      errors =
        analyze_errors("""
        module M {
          fn fetch() -> Result[String, HttpError] {
            Ok("h")
          }

          fn load() -> Result[String, StoreError] {
            Ok("s")
          }

          fn pick(use_http: Bool) -> Result[String, HttpError] {
            match use_http {
              true -> fetch()
              false -> load()
            }
          }
        }
        """)

      assert [%Skein.Error{code: "E0037"} = error] = errors
      assert error.message =~ "HttpError"
      assert error.message =~ "StoreError"
    end

    test "a widened component bound through a let still hits the boundary" do
      errors =
        analyze_errors("""
        module M {
          fn fetch() -> Result[String, HttpError] {
            Ok("h")
          }

          fn load() -> Result[String, StoreError] {
            Ok("s")
          }

          fn pick(use_http: Bool) -> Result[String, HttpError] {
            let r = match use_http {
              true -> fetch()
              false -> load()
            }
            r
          }
        }
        """)

      assert Enum.any?(errors, &(&1.code == "E0037"))
    end

    test "nested generic :unknown from effect tables still passes (C1 closes those)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 capability memory.kv("cache")

                 fn save() -> Result[String, MemoryError] {
                   memory.put("k", "v")
                 }
               }
               """)
    end

    test "a discarded widened match (not crossing a boundary) stays legal" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn fetch() -> Result[String, HttpError] {
                   Ok("h")
                 }

                 fn load() -> Result[String, StoreError] {
                   Ok("s")
                 }

                 fn pick(use_http: Bool) -> String {
                   let r = match use_http {
                     true -> fetch()
                     false -> load()
                   }
                   "done"
                 }
               }
               """)
    end
  end

  describe "Json is concrete, not a wildcard" do
    test "Json cannot flow into a String-typed return" do
      errors =
        analyze_errors("""
        module M {
          fn as_string(payload: Json) -> String {
            payload
          }
        }
        """)

      assert Enum.any?(errors, fn e ->
               e.code == "E0020" and e.message =~ "Json"
             end)
    end

    test "any value can flow into a Json-typed position (upcast)" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn wrap(s: String) -> Json {
                   s
                 }
               }
               """)
    end

    test "Json flows where Json is declared" do
      assert {:ok, _} =
               analyze("""
               module M {
                 fn pass(payload: Json) -> Json {
                   payload
                 }
               }
               """)
    end
  end
end
