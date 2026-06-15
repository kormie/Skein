defmodule Skein.Runtime.RequestTest do
  use ExUnit.Case, async: true

  alias Skein.Runtime.Request
  alias Skein.Runtime.ValidationError

  @user_schema %{
    "type" => "object",
    "properties" => %{
      "email" => %{"type" => "string"},
      "name" => %{"type" => "string"}
    },
    "required" => ["email", "name"]
  }

  # ------------------------------------------------------------------
  # json/2 — parse and validate request body
  # ------------------------------------------------------------------

  describe "json/2" do
    test "parses valid JSON body matching schema" do
      req = %{body: ~s({"email":"test@example.com","name":"Alice"})}

      assert {:ok, parsed} = Request.json(req, @user_schema)
      # Schema-declared keys are atomized so compiled field access works
      # (skein-testing #2); fields outside the schema stay strings.
      assert parsed.email == "test@example.com"
      assert parsed.name == "Alice"
    end

    test "returns a ValidationError for invalid JSON" do
      req = %{body: "not json at all"}

      assert {:error, %ValidationError{} = error} = Request.json(req, @user_schema)
      assert error.message =~ "JSON"
    end

    test "returns a ValidationError for empty body" do
      req = %{body: ""}

      assert {:error, %ValidationError{} = error} = Request.json(req, @user_schema)
      assert error.message =~ "JSON"
    end

    test "returns a ValidationError naming the missing required field" do
      req = %{body: ~s({"email":"test@example.com"})}

      assert {:error, %ValidationError{violations: violations}} = Request.json(req, @user_schema)
      assert Enum.any?(violations, &(&1 =~ "name"))
    end

    test "returns a ValidationError when a field has the wrong type" do
      req = %{body: ~s({"email":"test@example.com","name":123})}

      assert {:error, %ValidationError{violations: violations}} = Request.json(req, @user_schema)
      assert Enum.any?(violations, &(&1 =~ "name"))
    end

    test "enforces @one_of / @min / @max constraints (skein-testing#25)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "status" => %{"type" => "string", "enum" => ["new", "paid", "shipped"]},
          "qty" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        "required" => ["status", "qty"]
      }

      assert {:ok, _} = Request.json(%{body: ~s({"status":"new","qty":5})}, schema)

      assert {:error, %ValidationError{violations: v1}} =
               Request.json(%{body: ~s({"status":"BOGUS","qty":5})}, schema)

      assert Enum.any?(v1, &(&1 =~ "status"))

      assert {:error, %ValidationError{violations: v2}} =
               Request.json(%{body: ~s({"status":"new","qty":9999})}, schema)

      assert Enum.any?(v2, &(&1 =~ "qty"))

      assert {:error, %ValidationError{violations: v3}} =
               Request.json(%{body: ~s({"status":"new","qty":0})}, schema)

      assert Enum.any?(v3, &(&1 =~ "qty"))
    end

    test "coerces Option fields to Some/None (skein-testing#32)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "note" => %{"type" => "string", "x-skein-optional" => true}
        },
        "required" => ["name"]
      }

      # Present optional value -> Some(v)
      assert {:ok, present} = Request.json(%{body: ~s({"name":"n1","note":"hello"})}, schema)
      assert present.note == {:some, "hello"}

      # Absent optional field -> None
      assert {:ok, absent} = Request.json(%{body: ~s({"name":"n2"})}, schema)
      assert absent.note == :none
    end

    test "accepts object without required list (all fields optional)" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "note" => %{"type" => "string"}
        }
      }

      req = %{body: ~s({})}
      assert {:ok, parsed} = Request.json(req, schema)
      assert parsed == %{}
    end

    test "accepts empty schema (no validation)" do
      req = %{body: ~s({"anything":"goes"})}

      assert {:ok, parsed} = Request.json(req, %{})
      assert parsed["anything"] == "goes"
    end

    test "validates integer type" do
      schema = %{
        "type" => "object",
        "properties" => %{"count" => %{"type" => "integer"}},
        "required" => ["count"]
      }

      req_ok = %{body: ~s({"count":42})}
      assert {:ok, _} = Request.json(req_ok, schema)

      req_bad = %{body: ~s({"count":"not a number"})}
      assert {:error, _} = Request.json(req_bad, schema)
    end

    test "validates boolean type" do
      schema = %{
        "type" => "object",
        "properties" => %{"active" => %{"type" => "boolean"}},
        "required" => ["active"]
      }

      req_ok = %{body: ~s({"active":true})}
      assert {:ok, _} = Request.json(req_ok, schema)

      req_bad = %{body: ~s({"active":"yes"})}
      assert {:error, _} = Request.json(req_bad, schema)
    end

    test "validates number type" do
      schema = %{
        "type" => "object",
        "properties" => %{"price" => %{"type" => "number"}},
        "required" => ["price"]
      }

      req_ok = %{body: ~s({"price":9.99})}
      assert {:ok, _} = Request.json(req_ok, schema)

      req_int_ok = %{body: ~s({"price":10})}
      assert {:ok, _} = Request.json(req_int_ok, schema)

      req_bad = %{body: ~s({"price":"free"})}
      assert {:error, _} = Request.json(req_bad, schema)
    end

    test "validates array type" do
      schema = %{
        "type" => "object",
        "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}},
        "required" => ["tags"]
      }

      req_ok = %{body: ~s({"tags":["a","b","c"]})}
      assert {:ok, _} = Request.json(req_ok, schema)

      req_bad = %{body: ~s({"tags":"not-array"})}
      assert {:error, _} = Request.json(req_bad, schema)
    end

    test "allows extra fields not in schema" do
      req = %{body: ~s({"email":"test@example.com","name":"Alice","extra":"field"})}

      assert {:ok, parsed} = Request.json(req, @user_schema)
      assert parsed["extra"] == "field"
    end

    test "atomizes nested declared fields like the llm.json path" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        },
        "required" => ["user"]
      }

      req = %{body: ~s({"user":{"name":"Ada"}})}
      assert {:ok, parsed} = Request.json(req, schema)
      assert parsed.user.name == "Ada"
    end
  end
end
