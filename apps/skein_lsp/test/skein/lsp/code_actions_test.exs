defmodule Skein.Lsp.CodeActionsTest do
  @moduledoc """
  Unit tests for quickfix code actions derived from compiler `fix_code`.

  Diagnostics come from the real compile pipeline (`compile_diagnostics`)
  so the per-code edit mapping is pinned against the errors the compiler
  actually emits.
  """
  use ExUnit.Case, async: true

  alias GenLSP.Structures.{CodeAction, Position}
  alias Skein.Lsp.{CodeActions, Diagnostics}

  @uri "file:///tmp/code-actions.skein"

  defp actions_for(source) do
    {diagnostics, _ast} = Diagnostics.compile_diagnostics(source, "/tmp/code-actions.skein")
    CodeActions.actions(@uri, source, diagnostics)
  end

  defp single_edit(%CodeAction{edit: %{changes: changes}}) do
    [edit] = Map.fetch!(changes, @uri)
    edit
  end

  describe "missing-token inserts (E0001)" do
    test "missing ':' after description inserts the token after the keyword" do
      source = """
      module M {
        tool Acme.Do {
          description "x"
        }
      }
      """

      [action] = actions_for(source)
      assert action.kind == "quickfix"
      assert is_binary(action.title)

      edit = single_edit(action)
      assert edit.new_text == ":"
      # "description" starts at character 4 on line 2 (0-based); the token
      # inserts immediately after the keyword
      assert edit.range.start == %Position{line: 2, character: 15}
      assert edit.range.end == edit.range.start
    end
  end

  describe "missing capability inserts (E0012)" do
    test "inserts the capability line after the module opening" do
      source = """
      module M {
        fn f() -> String {
          http.get("https://example.com")
        }
      }
      """

      actions = actions_for(source)
      assert [action] = Enum.filter(actions, &(&1.title =~ "capability"))

      edit = single_edit(action)
      assert edit.new_text == "  capability http.out\n"
      assert edit.range.start == %Position{line: 1, character: 0}
    end

    test "inserts after the last existing capability line" do
      source = """
      module M {
        capability event.log("audit")

        fn f() -> String {
          event.log("a", "b")
          http.get("https://example.com")
        }
      }
      """

      actions = actions_for(source)
      assert [action] = Enum.filter(actions, &(&1.title =~ "capability"))

      edit = single_edit(action)
      assert edit.new_text == "  capability http.out\n"
      assert edit.range.start == %Position{line: 2, character: 0}
    end
  end

  describe "unused declaration deletes (W0002)" do
    test "removes the unused capability's line" do
      source = """
      module M {
        capability timer("maintenance")

        fn f() -> String {
          "ok"
        }
      }
      """

      [action] = actions_for(source)

      edit = single_edit(action)
      assert edit.new_text == ""
      assert edit.range.start == %Position{line: 1, character: 0}
      assert edit.range.end == %Position{line: 2, character: 0}
    end
  end

  describe "unused binding rename (W0001)" do
    test "replaces the binding name with the underscore-prefixed fix" do
      source = """
      module M {
        fn f() -> String {
          let unused = 1
          "ok"
        }
      }
      """

      [action] = actions_for(source)

      edit = single_edit(action)
      assert edit.new_text == "_unused"
      assert edit.range.start.line == 2
      assert edit.range.end.line == 2

      line = source |> String.split("\n") |> Enum.at(2)

      assert String.slice(line, edit.range.start.character, 6) == "unused"
      assert edit.range.end.character - edit.range.start.character == 6
    end
  end

  describe "errors without an applicable fix" do
    test "produce no action" do
      source = """
      module M {
        fn f() -> Int {
          "nope"
        }
      }
      """

      assert actions_for(source) == []
    end
  end
end
