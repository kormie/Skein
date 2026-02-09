defmodule Skein.ErrorTest do
  @moduledoc """
  Unit tests for the Skein.Error struct and its JSON serialization.
  """
  use ExUnit.Case, async: true

  alias Skein.Error

  describe "struct" do
    test "can be constructed with all fields" do
      error = %Error{
        code: "E0001",
        severity: :error,
        message: "Unexpected token",
        location: %{file: "test.skein", line: 1, col: 5},
        context: "let x = ",
        fix_hint: "Expected an expression after '='",
        fix_code: "let x = 42"
      }

      assert error.code == "E0001"
      assert error.severity == :error
      assert error.message == "Unexpected token"
      assert error.location.file == "test.skein"
      assert error.location.line == 1
      assert error.location.col == 5
      assert error.context == "let x = "
      assert error.fix_hint == "Expected an expression after '='"
      assert error.fix_code == "let x = 42"
    end

    test "optional fields default to nil" do
      error = %Error{
        code: "E0002",
        severity: :warning,
        message: "Unused variable",
        location: %{file: "test.skein", line: 3, col: 7}
      }

      assert error.context == nil
      assert error.fix_hint == nil
      assert error.fix_code == nil
    end
  end

  describe "to_json/1" do
    test "serializes all fields to JSON" do
      error = %Error{
        code: "E0001",
        severity: :error,
        message: "Unexpected token 'let'",
        location: %{file: "test.skein", line: 10, col: 3},
        context: "fn foo() { let }",
        fix_hint: "Add an expression after 'let'",
        fix_code: "let x = value"
      }

      json = Error.to_json(error)
      decoded = Jason.decode!(json)

      assert decoded["code"] == "E0001"
      assert decoded["severity"] == "error"
      assert decoded["message"] == "Unexpected token 'let'"
      assert decoded["location"]["file"] == "test.skein"
      assert decoded["location"]["line"] == 10
      assert decoded["location"]["col"] == 3
      assert decoded["context"] == "fn foo() { let }"
      assert decoded["fix_hint"] == "Add an expression after 'let'"
      assert decoded["fix_code"] == "let x = value"
    end

    test "serializes nil optional fields as null" do
      error = %Error{
        code: "E0010",
        severity: :warning,
        message: "Non-exhaustive match",
        location: %{file: "main.skein", line: 5, col: 1}
      }

      json = Error.to_json(error)
      decoded = Jason.decode!(json)

      assert decoded["context"] == nil
      assert decoded["fix_hint"] == nil
      assert decoded["fix_code"] == nil
    end

    test "produces valid JSON string" do
      error = %Error{
        code: "E0001",
        severity: :error,
        message: "Error with \"quotes\" and \\ backslash",
        location: %{file: "test.skein", line: 1, col: 1}
      }

      json = Error.to_json(error)
      assert is_binary(json)
      # Round-trip should work
      assert {:ok, _} = Jason.decode(json)
    end
  end

  describe "to_json_list/1" do
    test "serializes a list of errors" do
      errors = [
        %Error{
          code: "E0001",
          severity: :error,
          message: "First error",
          location: %{file: "test.skein", line: 1, col: 1}
        },
        %Error{
          code: "E0002",
          severity: :warning,
          message: "Second warning",
          location: %{file: "test.skein", line: 5, col: 10},
          fix_hint: "Remove unused variable"
        }
      ]

      json = Error.to_json_list(errors)
      decoded = Jason.decode!(json)

      assert is_list(decoded["errors"])
      assert length(decoded["errors"]) == 2
      assert hd(decoded["errors"])["code"] == "E0001"
      assert List.last(decoded["errors"])["code"] == "E0002"
      assert List.last(decoded["errors"])["fix_hint"] == "Remove unused variable"
    end

    test "serializes empty error list" do
      json = Error.to_json_list([])
      decoded = Jason.decode!(json)
      assert decoded["errors"] == []
    end
  end
end
