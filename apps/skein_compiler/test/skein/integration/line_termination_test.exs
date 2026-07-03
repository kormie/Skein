defmodule Skein.Integration.LineTerminationTest do
  @moduledoc """
  A `(` that starts a new line never continues the previous expression as a
  call (#311). Before this, `let x = "s"` followed by `(1 + 2)` on the next
  line parsed as the call `"s"(1 + 2)` — a production that can only build
  programs the analyzer must reject (expression calls are E0020), so it
  existed solely to turn well-intentioned two-line programs into misleading
  rejections. Same-line calls, multi-line argument lists, and the
  `expr[T](args)` form are unaffected.

  The Skein module name (`LineTermM`) must stay unique to this file:
  this async suite runs compiled code, and a shared name gets purge-killed
  by other suites' `:code.load_binary` reloads (#338).
  """
  use ExUnit.Case, async: true

  alias Skein.Compiler

  describe "a newline terminates the call chain" do
    test "a paren group on its own line after a let is a new expression" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module LineTermM {
                 fn f() -> Int {
                   let _s = "not a callee"
                   (1 + 2) * 10
                 }
               }
               """)

      assert mod.f() == 30
    end

    test "a paren group on its own line after a call result is a new expression" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module LineTermM {
                 fn one() -> Int { 1 }
                 fn f() -> Int {
                   let _x = one()
                   (2 + 3)
                 }
               }
               """)

      assert mod.f() == 5
    end

    test "a fn name followed by a newline paren group is NOT a call (bare-fn error, not a misparse)" do
      assert {:error, errors} =
               Compiler.compile_string("""
               module LineTermM {
                 fn g() -> Int { 1 }
                 fn f() -> Int {
                   let _x = g
                   (1 + 2)
                 }
               }
               """)

      # The right diagnosis: `g` is a bare fn name (E0020 with the &g fix) —
      # not "this expression cannot be called" pointing at the paren group.
      assert Enum.any?(errors, &(&1.fix_code == "&g"))
      refute Enum.any?(errors, &(&1.message =~ "cannot be called"))
    end
  end

  describe "same-line calls are unaffected" do
    test "plain, dotted, and unwrapped calls still parse as calls" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module LineTermM {
                 fn double(n: Int) -> Int { n * 2 }
                 fn half(n: Int) -> Result[Int, String] { Ok(n / 2) }
                 fn f() -> Int {
                   let d = double(4)
                   let h = half(d)!
                   String.length("abc") + h
                 }
               }
               """)

      assert mod.f() == 7
    end

    test "a call may still spread its ARGUMENTS across lines" do
      assert {:module, mod} =
               Compiler.compile_string("""
               module LineTermM {
                 fn add(a: Int, b: Int) -> Int { a + b }
                 fn f() -> Int {
                   add(
                     1,
                     2
                   )
                 }
               }
               """)

      assert mod.f() == 3
    end

    test "the type-parameterized call form still parses on one line" do
      # req.json[T] inside a handler — the [T](...) production.
      assert {:module, _} =
               Compiler.compile_string("""
               module LineTermM {
                 capability http.in
                 type User { name: String }
                 handler http POST "/u" (req) -> {
                   let user = req.json[User]!
                   respond.json(200, user.name)
                 }
               }
               """)
    end
  end
end
