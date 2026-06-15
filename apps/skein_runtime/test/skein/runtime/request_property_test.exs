defmodule Skein.Runtime.RequestPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Runtime.Request

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  defp valid_json_string do
    gen all(value <- StreamData.string(:alphanumeric, min_length: 1)) do
      value
    end
  end

  defp valid_json_object(fields) do
    generators =
      Map.new(fields, fn {name, type} ->
        {name, generator_for_type(type)}
      end)

    gen all(values <- StreamData.fixed_map(generators)) do
      values
    end
  end

  defp generator_for_type("string"), do: valid_json_string()
  defp generator_for_type("integer"), do: StreamData.integer()
  defp generator_for_type("number"), do: StreamData.float(min: -1.0e6, max: 1.0e6)
  defp generator_for_type("boolean"), do: StreamData.boolean()

  defp generator_for_type("array") do
    gen all(items <- StreamData.list_of(valid_json_string(), max_length: 5)) do
      items
    end
  end

  # ------------------------------------------------------------------
  # Properties: valid JSON always parses
  # ------------------------------------------------------------------

  property "valid JSON matching schema always succeeds" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "age" => %{"type" => "integer"}
      },
      "required" => ["name", "age"]
    }

    check all(obj <- valid_json_object(%{"name" => "string", "age" => "integer"})) do
      body = Jason.encode!(obj)
      req = %{body: body}
      assert {:ok, parsed} = Request.json(req, schema)
      assert parsed[:name] == obj["name"]
      assert parsed[:age] == obj["age"]
    end
  end

  property "empty schema accepts any valid JSON object" do
    check all(obj <- valid_json_object(%{"x" => "string"})) do
      body = Jason.encode!(obj)
      req = %{body: body}
      assert {:ok, _} = Request.json(req, %{})
    end
  end

  property "non-JSON strings always return error" do
    check all(
            bad_body <-
              StreamData.filter(
                StreamData.string(:alphanumeric, min_length: 1),
                fn s -> match?({:error, _}, Jason.decode(s)) end
              )
          ) do
      req = %{body: bad_body}
      schema = %{"type" => "object", "properties" => %{}, "required" => []}
      assert {:error, %Skein.Runtime.ValidationError{} = error} = Request.json(req, schema)
      assert error.message =~ "JSON"
    end
  end

  property "missing required fields always produce errors" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "required_field" => %{"type" => "string"}
      },
      "required" => ["required_field"]
    }

    check all(obj <- StreamData.fixed_map(%{"other" => valid_json_string()})) do
      body = Jason.encode!(obj)
      req = %{body: body}
      assert {:error, %Skein.Runtime.ValidationError{} = error} = Request.json(req, schema)
      assert error.message =~ "required_field"
    end
  end

  property "wrong type values produce errors" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "count" => %{"type" => "integer"}
      },
      "required" => ["count"]
    }

    check all(bad_value <- valid_json_string()) do
      body = Jason.encode!(%{"count" => bad_value})
      req = %{body: body}
      assert {:error, %Skein.Runtime.ValidationError{} = error} = Request.json(req, schema)
      assert error.message =~ "count"
    end
  end

  property "all supported types validate correctly when correct" do
    types = [
      {"string", valid_json_string()},
      {"integer", StreamData.integer()},
      {"boolean", StreamData.boolean()}
    ]

    check all(
            {type_name, gen} <- StreamData.member_of(types),
            value <- gen
          ) do
      schema = %{
        "type" => "object",
        "properties" => %{"field" => %{"type" => type_name}},
        "required" => ["field"]
      }

      body = Jason.encode!(%{"field" => value})
      req = %{body: body}
      assert {:ok, _} = Request.json(req, schema)
    end
  end
end
