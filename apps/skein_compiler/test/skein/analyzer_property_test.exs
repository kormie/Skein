defmodule Skein.AnalyzerPropertyTest do
  @moduledoc """
  Property-based tests for the Skein analyzer.

  Uses StreamData generators to verify capability checking invariants
  across large input spaces.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  @http_methods ~w(get post put patch delete)

  defp http_method_gen do
    StreamData.member_of(@http_methods)
  end

  defp host_gen do
    gen all(
          subdomain <-
            StreamData.string(Enum.to_list(?a..?z), min_length: 3, max_length: 10),
          domain <-
            StreamData.string(Enum.to_list(?a..?z), min_length: 3, max_length: 8),
          tld <- StreamData.member_of(~w(com org net io dev))
        ) do
      "#{subdomain}.#{domain}.#{tld}"
    end
  end

  defp analyze(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, ast} = Parser.parse(tokens)
    Analyzer.analyze(ast)
  end

  defp analyze_errors(source) do
    case analyze(source) do
      {:error, errors} -> errors
      {:ok, _} -> []
    end
  end

  # ------------------------------------------------------------------
  # Properties
  # ------------------------------------------------------------------

  property "any http method without capability produces E0030 error" do
    check all(method <- http_method_gen()) do
      # Build args based on method — post/put/patch need a body arg
      args =
        if method in ["post", "put", "patch"] do
          "url, body"
        else
          "url"
        end

      params =
        if method in ["post", "put", "patch"] do
          "url: String, body: String"
        else
          "url: String"
        end

      source = """
      module TestMod {
        fn fetch(#{params}) -> String {
          http.#{method}(#{args})
        }
      }
      """

      errors = analyze_errors(source)
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))

      assert length(capability_errors) >= 1,
             "Expected E0030 error for http.#{method} without capability, got none"
    end
  end

  property "any http method with capability http.out passes" do
    check all(
            method <- http_method_gen(),
            host <- host_gen()
          ) do
      args =
        if method in ["post", "put", "patch"] do
          "url, body"
        else
          "url"
        end

      params =
        if method in ["post", "put", "patch"] do
          "url: String, body: String"
        else
          "url: String"
        end

      source = """
      module TestMod {
        capability http.out("#{host}")

        fn fetch(#{params}) -> String {
          http.#{method}(#{args})
        }
      }
      """

      result = analyze(source)
      assert {:ok, _} = result, "Expected ok for http.#{method} with capability, got error"
    end
  end

  property "capability errors always include fix_code containing 'capability http.out'" do
    check all(method <- http_method_gen()) do
      args =
        if method in ["post", "put", "patch"] do
          "url, body"
        else
          "url"
        end

      params =
        if method in ["post", "put", "patch"] do
          "url: String, body: String"
        else
          "url: String"
        end

      source = """
      module TestMod {
        fn fetch(#{params}) -> String {
          http.#{method}(#{args})
        }
      }
      """

      errors = analyze_errors(source)
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))

      for error <- capability_errors do
        assert error.fix_code =~ "capability http.out",
               "fix_code should contain 'capability http.out', got: #{inspect(error.fix_code)}"
      end
    end
  end

  property "capability errors are always JSON-serializable" do
    check all(method <- http_method_gen()) do
      args = if method in ["post", "put", "patch"], do: "url, body", else: "url"

      params =
        if method in ["post", "put", "patch"],
          do: "url: String, body: String",
          else: "url: String"

      source = """
      module TestMod {
        fn fetch(#{params}) -> String {
          http.#{method}(#{args})
        }
      }
      """

      errors = analyze_errors(source)
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))

      for error <- capability_errors do
        json = Skein.Error.to_json(error)
        decoded = Jason.decode!(json)
        assert decoded["code"] == "E0030"
        assert is_binary(decoded["message"])
        assert is_binary(decoded["fix_code"])
        assert is_binary(decoded["fix_hint"])
      end
    end
  end

  property "modules without effect calls never produce E0030 errors" do
    check all(
            a <- StreamData.positive_integer(),
            b <- StreamData.positive_integer()
          ) do
      source = """
      module PureMod {
        fn add(x: Int, y: Int) -> Int {
          x + y
        }

        fn constant() -> Int {
          #{a + b}
        }
      }
      """

      errors = analyze_errors(source)
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))
      assert capability_errors == [], "Pure module should never get E0030 errors"
    end
  end

  property "N distinct effect calls without capability produce N errors" do
    check all(
            methods <-
              StreamData.uniq_list_of(http_method_gen(), min_length: 1, max_length: 3)
          ) do
      fn_defs =
        methods
        |> Enum.with_index()
        |> Enum.map(fn {method, idx} ->
          {args, params} =
            if method in ["post", "put", "patch"] do
              {"url, body", "url: String, body: String"}
            else
              {"url", "url: String"}
            end

          """
            fn fetch_#{idx}(#{params}) -> String {
              http.#{method}(#{args})
            }
          """
        end)
        |> Enum.join("\n")

      source = """
      module MultiMod {
        #{fn_defs}
      }
      """

      errors = analyze_errors(source)
      capability_errors = Enum.filter(errors, &(&1.code == "E0030"))

      assert length(capability_errors) == length(methods),
             "Expected #{length(methods)} E0030 errors, got #{length(capability_errors)}"
    end
  end
end
