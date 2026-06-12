defmodule Skein.Error.EditTest do
  @moduledoc """
  Unit tests for the reference fix applier (`Skein.Error.Edit`), pinning
  the semantics of each `edit_kind` on `Skein.Error`.
  """
  use ExUnit.Case, async: true

  alias Skein.Error
  alias Skein.Error.Edit

  defp error(kind, span, fix_code) do
    %Error{
      code: "E0000",
      severity: :error,
      message: "test",
      location: %{file: "test.skein", line: 1, col: 1},
      fix_code: fix_code,
      span: span,
      edit_kind: kind
    }
  end

  describe "replace" do
    test "replaces the spanned text" do
      source = "let amout = 1"
      err = error(:replace, Error.span(1, 5, 5), "amount")
      assert {:ok, "let amount = 1"} = Edit.apply_fix(source, err)
    end

    test "an empty fix_code deletes the spanned text" do
      source = "let x = 1;"
      err = error(:replace, Error.span(1, 10, 1), "")
      assert {:ok, "let x = 1"} = Edit.apply_fix(source, err)
    end

    test "works on a middle line" do
      source = "a\nlet amout = 1\nb"
      err = error(:replace, Error.span(2, 5, 5), "amount")
      assert {:ok, "a\nlet amount = 1\nb"} = Edit.apply_fix(source, err)
    end
  end

  describe "insert_before / insert_after" do
    test "insert_before inserts at the span start" do
      source = "fn f() -> Int 42"
      err = error(:insert_before, Error.span(1, 15, 2), "{ ")
      assert {:ok, "fn f() -> Int { 42"} = Edit.apply_fix(source, err)
    end

    test "insert_after inserts at the span end" do
      source = "description \"x\""
      err = error(:insert_after, Error.span(1, 1, 11), ":")
      assert {:ok, "description: \"x\""} = Edit.apply_fix(source, err)
    end

    test "insert_after with a point span inserts at that point" do
      source = ~S(let s = "${name)
      err = error(:insert_after, Error.point(1, 16), "}")
      assert {:ok, ~S(let s = "${name})} = Edit.apply_fix(source, err)
    end
  end

  describe "insert_line" do
    test "inserts the fix as a new indented line, pushing lines down" do
      source = "module M {\n  fn f() -> Int { 1 }\n}"
      err = error(:insert_line, Error.point(2, 3), "capability http.out")

      assert {:ok, "module M {\n  capability http.out\n  fn f() -> Int { 1 }\n}"} =
               Edit.apply_fix(source, err)
    end

    test "can append after the last line" do
      source = "a"
      err = error(:insert_line, Error.point(2, 1), "b")
      assert {:ok, "a\nb"} = Edit.apply_fix(source, err)
    end
  end

  describe "delete_line" do
    test "removes the spanned line" do
      source = "a\n  capability timer\nb"
      err = error(:delete_line, Error.span(2, 3, 10), "")
      assert {:ok, "a\nb"} = Edit.apply_fix(source, err)
    end

    test "removes a multi-line span" do
      source = "a\nx\ny\nb"

      err =
        error(
          :delete_line,
          %{start: %{line: 2, col: 1}, end: %{line: 3, col: 1}},
          nil
        )

      assert {:ok, "a\nb"} = Edit.apply_fix(source, err)
    end
  end

  describe "not applicable" do
    test "no edit_kind" do
      err = error(nil, Error.span(1, 1, 1), "x")
      assert Edit.apply_fix("source", err) == :not_applicable
    end

    test "no span" do
      err = error(:replace, nil, "x")
      assert Edit.apply_fix("source", err) == :not_applicable
    end

    test "replace without fix_code" do
      err = error(:replace, Error.span(1, 1, 1), nil)
      assert Edit.apply_fix("source", err) == :not_applicable
    end

    test "span beyond the source" do
      err = error(:replace, Error.span(9, 1, 1), "x")
      assert Edit.apply_fix("a", err) == :not_applicable
    end
  end
end
