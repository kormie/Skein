defmodule Skein.Lsp.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Skein.Lsp.Diagnostics

  describe "compile_diagnostics/2" do
    test "returns empty diagnostics for valid source" do
      source = """
      module Hello {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """

      {diagnostics, ast} = Diagnostics.compile_diagnostics(source, "test.skein")

      assert diagnostics == []
      assert ast != nil
    end

    test "returns diagnostics for invalid syntax" do
      source = """
      module Hello {
        fn greet( -> {
        }
      }
      """

      {diagnostics, _ast} = Diagnostics.compile_diagnostics(source, "test.skein")

      assert length(diagnostics) > 0
      [diag | _] = diagnostics
      assert diag.source == "skein"
      assert diag.severity == GenLSP.Enumerations.DiagnosticSeverity.error()
    end

    test "returns diagnostics with error codes" do
      source = """
      module Hello {
        fn greet( -> {
        }
      }
      """

      {diagnostics, _ast} = Diagnostics.compile_diagnostics(source, "test.skein")

      [diag | _] = diagnostics
      assert is_binary(diag.code)
      assert String.starts_with?(diag.message, "[E")
    end

    test "returns AST even when analyzer finds warnings" do
      source = """
      module Hello {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """

      {diagnostics, ast} = Diagnostics.compile_diagnostics(source, "test.skein")

      assert diagnostics == []
      assert ast != nil
    end

    test "returns lexer errors for invalid tokens" do
      source = "module Hello { fn greet() -> { ` } }"

      {diagnostics, ast} = Diagnostics.compile_diagnostics(source, "test.skein")

      assert length(diagnostics) > 0
      assert ast == nil
    end
  end

  describe "errors_to_diagnostics/1" do
    test "converts Skein errors to LSP diagnostics" do
      errors = [
        %Skein.Error{
          code: "E0001",
          severity: :error,
          message: "Unexpected token",
          location: %{file: "test.skein", line: 5, col: 3},
          context: nil,
          fix_hint: "Expected '}' to close block",
          fix_code: nil
        }
      ]

      diagnostics = Diagnostics.errors_to_diagnostics(errors)

      assert length(diagnostics) == 1
      [diag] = diagnostics
      assert diag.range.start.line == 4
      assert diag.range.start.character == 2
      assert diag.code == "E0001"
      assert diag.severity == GenLSP.Enumerations.DiagnosticSeverity.error()
      assert String.contains?(diag.message, "Unexpected token")
      assert String.contains?(diag.message, "Hint:")
    end

    test "converts warnings correctly" do
      errors = [
        %Skein.Error{
          code: "E0024",
          severity: :warning,
          message: "Non-exhaustive match",
          location: %{file: "test.skein", line: 10, col: 5},
          context: nil,
          fix_hint: nil,
          fix_code: nil
        }
      ]

      diagnostics = Diagnostics.errors_to_diagnostics(errors)

      [diag] = diagnostics
      assert diag.severity == GenLSP.Enumerations.DiagnosticSeverity.warning()
    end

    test "handles missing location gracefully" do
      errors = [
        %Skein.Error{
          code: "E0001",
          severity: :error,
          message: "Some error",
          location: %{file: "test.skein", line: 0, col: 0},
          context: nil,
          fix_hint: nil,
          fix_code: nil
        }
      ]

      diagnostics = Diagnostics.errors_to_diagnostics(errors)

      [diag] = diagnostics
      assert diag.range.start.line == 0
      assert diag.range.start.character == 0
    end

    test "ships code, fix_hint, and fix_code in diagnostic data" do
      errors = [
        %Skein.Error{
          code: "E0001",
          severity: :error,
          message: "Missing ':' after 'description'",
          location: %{file: "test.skein", line: 3, col: 5},
          context: nil,
          fix_hint: "Add ':' after 'description'",
          fix_code: ":"
        }
      ]

      [diag] = Diagnostics.errors_to_diagnostics(errors)

      assert diag.data == %{
               "code" => "E0001",
               "fix_hint" => "Add ':' after 'description'",
               "fix_code" => ":",
               "span" => nil,
               "edit_kind" => nil
             }
    end

    test "ships span and edit_kind in diagnostic data and uses the span for the range" do
      errors = [
        %Skein.Error{
          code: "W0001",
          severity: :warning,
          message: "Unused binding 'order'",
          location: %{file: "test.skein", line: 3, col: 3},
          fix_hint: "Remove this binding or prefix with _",
          fix_code: "_order",
          span: Skein.Error.span(3, 7, 5),
          edit_kind: :replace
        }
      ]

      [diag] = Diagnostics.errors_to_diagnostics(errors)

      assert diag.data["span"] == %{
               "start" => %{"line" => 3, "col" => 7},
               "end" => %{"line" => 3, "col" => 12}
             }

      assert diag.data["edit_kind"] == "replace"

      # The diagnostic range is the span (0-based)
      assert diag.range.start.line == 2
      assert diag.range.start.character == 6
      assert diag.range.end.character == 11
    end
  end
end
