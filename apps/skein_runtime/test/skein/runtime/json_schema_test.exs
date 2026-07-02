defmodule Skein.Runtime.JsonSchemaTest do
  @moduledoc """
  The one recursive schema engine (C3/#298): `validate/2` enforces every
  feature the derived schemas emit — nested objects/arrays, `required`,
  `enum`, `minimum`/`maximum`, `uniqueItems`, `format`, `oneOf`,
  `additionalProperties` — and `decode/2` composes validation with the
  existing key atomization, so `req.json[T]`, `llm.json[T]`, and tool
  input/output all share one contract.
  """
  use ExUnit.Case, async: true

  alias Skein.Runtime.JsonSchema

  @user_schema %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
      "email" => %{"type" => "string", "format" => "email"},
      "id" => %{"type" => "string", "format" => "uuid"},
      "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
      "scores" => %{"type" => "array", "uniqueItems" => true, "items" => %{"type" => "integer"}},
      "address" => %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"},
          "zip" => %{"type" => "string"}
        },
        "required" => ["city"]
      },
      "nickname" => %{"type" => "string", "x-skein-optional" => true},
      "role" => %{"type" => "string", "enum" => ["admin", "user"]}
    },
    "required" => ["name", "age"]
  }

  defp valid_user do
    %{
      "name" => "Ada",
      "age" => 36,
      "email" => "ada@example.com",
      "id" => "00000000-0000-4000-8000-000000000001",
      "tags" => ["math", "computing"],
      "scores" => [1, 2, 3],
      "address" => %{"city" => "London", "zip" => "N1"},
      "role" => "admin"
    }
  end

  describe "validate/2" do
    test "a fully valid nested value passes" do
      assert :ok = JsonSchema.validate(valid_user(), @user_schema)
    end

    test "an empty schema is permissive (Json)" do
      assert :ok = JsonSchema.validate(%{"anything" => [1, "two"]}, %{})
    end

    test "missing required fields are reported by name" do
      assert {:error, violations} = JsonSchema.validate(%{"age" => 1}, @user_schema)
      assert Enum.any?(violations, &(&1 =~ "name"))
    end

    test "top-level type mismatches are reported" do
      assert {:error, [violation]} =
               JsonSchema.validate(valid_user() |> Map.put("age", "old"), @user_schema)

      assert violation =~ "age"
      assert violation =~ "integer"
    end

    test "NESTED object violations are reported with their path" do
      value = put_in(valid_user(), ["address", "city"], 42)
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "address.city"
    end

    test "a nested object missing ITS required field is caught" do
      value = Map.put(valid_user(), "address", %{"zip" => "N1"})
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "address"
      assert violation =~ "city"
    end

    test "array ELEMENT types are enforced (dead until C3)" do
      value = Map.put(valid_user(), "tags", ["ok", 42])
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "tags[1]"
    end

    test "uniqueItems is enforced (dead until C3)" do
      value = Map.put(valid_user(), "scores", [1, 2, 1])
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "scores"
      assert violation =~ "unique"
    end

    test "uuid format is enforced (dead until C3)" do
      value = Map.put(valid_user(), "id", "not-a-uuid")
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "id"
      assert violation =~ "uuid"
    end

    test "email format is enforced" do
      value = Map.put(valid_user(), "email", "not-an-email")
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "email"
    end

    test "date-time format is enforced" do
      schema = %{
        "type" => "object",
        "properties" => %{"at" => %{"type" => "string", "format" => "date-time"}}
      }

      assert :ok = JsonSchema.validate(%{"at" => "2026-07-02T12:00:00Z"}, schema)
      assert {:error, [violation]} = JsonSchema.validate(%{"at" => "yesterday"}, schema)
      assert violation =~ "date-time"
    end

    test "enum constraints are enforced" do
      value = Map.put(valid_user(), "role", "root")
      assert {:error, [violation]} = JsonSchema.validate(value, @user_schema)
      assert violation =~ "role"
    end

    test "minimum/maximum are enforced" do
      assert {:error, [v1]} = JsonSchema.validate(Map.put(valid_user(), "age", -1), @user_schema)
      assert v1 =~ ">="
      assert {:error, [v2]} = JsonSchema.validate(Map.put(valid_user(), "age", 200), @user_schema)
      assert v2 =~ "<="
    end

    test "absent optional fields pass; present ones validate their inner schema" do
      assert :ok = JsonSchema.validate(valid_user(), @user_schema)
      assert :ok = JsonSchema.validate(Map.put(valid_user(), "nickname", "A"), @user_schema)

      assert {:error, [violation]} =
               JsonSchema.validate(Map.put(valid_user(), "nickname", 42), @user_schema)

      assert violation =~ "nickname"
    end

    test "already-tagged Option values validate their inner value" do
      assert :ok =
               JsonSchema.validate(Map.put(valid_user(), "nickname", {:some, "A"}), @user_schema)

      assert :ok = JsonSchema.validate(Map.put(valid_user(), "nickname", :none), @user_schema)

      assert {:error, [violation]} =
               JsonSchema.validate(Map.put(valid_user(), "nickname", {:some, 42}), @user_schema)

      assert violation =~ "nickname"
    end

    test "atom-keyed maps validate like string-keyed ones (internal round trips)" do
      assert :ok = JsonSchema.validate(%{name: "Ada", age: 36}, @user_schema)
      assert {:error, _} = JsonSchema.validate(%{name: "Ada"}, @user_schema)
    end

    test "additionalProperties (Map[K, V]) validates every value recursively" do
      schema = %{
        "type" => "object",
        "additionalProperties" => %{"type" => "integer"}
      }

      assert :ok = JsonSchema.validate(%{"a" => 1, "b" => 2}, schema)
      assert {:error, [violation]} = JsonSchema.validate(%{"a" => 1, "b" => "x"}, schema)
      assert violation =~ "b"
    end

    test "oneOf accepts a matching branch and rejects a value matching none" do
      schema = %{
        "oneOf" => [
          %{
            "type" => "object",
            "properties" => %{"type" => %{"const" => "a"}, "n" => %{"type" => "integer"}},
            "required" => ["n"]
          },
          %{
            "type" => "object",
            "properties" => %{"type" => %{"const" => "b"}, "s" => %{"type" => "string"}},
            "required" => ["s"]
          }
        ]
      }

      assert :ok = JsonSchema.validate(%{"type" => "a", "n" => 1}, schema)
      assert :ok = JsonSchema.validate(%{"type" => "b", "s" => "x"}, schema)
      assert {:error, [violation]} = JsonSchema.validate(%{"type" => "a", "s" => "x"}, schema)
      assert violation =~ "oneOf" or violation =~ "n"
    end

    test "multiple violations are all reported" do
      value =
        valid_user()
        |> Map.put("age", "old")
        |> Map.put("role", "root")
        |> Map.put("tags", [1])

      assert {:error, violations} = JsonSchema.validate(value, @user_schema)
      assert length(violations) == 3
    end
  end

  describe "decode/2" do
    test "validates then atomizes in one step" do
      assert {:ok, decoded} = JsonSchema.decode(valid_user(), @user_schema)
      assert decoded.name == "Ada"
      assert decoded.address.city == "London"
      # absent optional field is injected as :none
      assert decoded.nickname == :none
    end

    test "returns the violations instead of decoding an invalid value" do
      assert {:error, violations} = JsonSchema.decode(%{"age" => "old"}, @user_schema)
      assert is_list(violations) and violations != []
    end
  end
end
