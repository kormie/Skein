defmodule Skein.CompilerErrorsTest do
  use ExUnit.Case

  alias Skein.Compiler

  @moduletag :tmp_dir

  describe "compile_file/1 error reporting" do
    test "lexer errors carry the source file path, not 'unknown'", %{tmp_dir: tmp} do
      path = Path.join(tmp, "semi.skein")

      File.write!(path, """
      module Semi {
        fn hello() -> String {
          "hi";
        }
      }
      """)

      assert {:error, [error]} = Compiler.compile_file(path)
      assert error.location.file == path
      assert error.location.line == 3
    end

    test "parser errors carry the source file path", %{tmp_dir: tmp} do
      path = Path.join(tmp, "broken.skein")

      File.write!(path, """
      module Broken {
        fn hello() -> String {
      """)

      assert {:error, [error | _]} = Compiler.compile_file(path)
      assert error.location.file == path
    end

    test "analyzer errors carry the source file path", %{tmp_dir: tmp} do
      path = Path.join(tmp, "unknown_ident.skein")

      File.write!(path, """
      module UnknownIdent {
        fn hello() -> String {
          undefined_variable
        }
      }
      """)

      assert {:error, errors} = Compiler.compile_file(path)
      assert Enum.any?(errors, &(&1.location.file == path))
    end

    test "missing file produces a readable message", %{tmp_dir: tmp} do
      path = Path.join(tmp, "does_not_exist.skein")
      assert {:error, message} = Compiler.compile_file(path)
      assert message == "File not found: #{path}"
    end

    test "directory argument produces a readable message with a hint", %{tmp_dir: tmp} do
      assert {:error, message} = Compiler.compile_file(tmp)
      assert message =~ "is a directory"
      assert message =~ "skein build"
    end

    test "compile_to_binary reports missing files readably", %{tmp_dir: tmp} do
      path = Path.join(tmp, "nope.skein")
      assert {:error, "File not found: " <> _} = Compiler.compile_to_binary(path)
    end
  end

  describe "targeted hints for habits from other languages" do
    test "semicolon errors explain that Skein has no semicolons", %{tmp_dir: tmp} do
      path = Path.join(tmp, "semi.skein")

      File.write!(path, """
      module Semi {
        fn hello() -> String {
          "hi";
        }
      }
      """)

      assert {:error, [error]} = Compiler.compile_file(path)
      assert error.message == "Unexpected character: ;"
      assert error.fix_hint =~ "does not use semicolons"
    end

    test "'return' errors explain last-expression semantics" do
      source = """
      module Returner {
        fn hello() -> String {
          return "hi"
        }
      }
      """

      assert {:error, errors} = Compiler.compile_string(source)
      return_error = Enum.find(errors, &(&1.message == "Unknown identifier 'return'"))
      assert return_error
      assert return_error.fix_hint =~ "no 'return' statement"
      assert return_error.fix_hint =~ "last expression"
    end
  end
end
