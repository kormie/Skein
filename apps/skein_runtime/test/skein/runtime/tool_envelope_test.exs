defmodule Skein.Runtime.ToolEnvelopeTest do
  @moduledoc """
  Runtime wiring of scenario capability envelopes (#282): `tool.call` pushes the
  registered envelope for the tool, and effect resolution (here `uuid`) consults
  the envelope's `implement` provider first. In production no envelope is
  registered, so `tool.call` is unaffected.
  """
  use ExUnit.Case, async: false

  alias Skein.Runtime.{CapabilityStack, Http, Llm, Nondeterminism, Tool}

  setup do
    Tool.clear_registry()
    CapabilityStack.clear()
    on_exit(fn -> CapabilityStack.clear() end)
    :ok
  end

  @caps [%{kind: "tool.use", params: ["Ids.New"]}]

  defp register_uuid_tool do
    Tool.register("Ids.New", %{}, fn _input -> {:ok, %{id: Nondeterminism.uuid()}} end)
  end

  test "tool.call pushes the registered envelope; uuid resolves from the provider" do
    register_uuid_tool()

    CapabilityStack.register_envelopes(%{
      "Ids.New" => %{
        tool: "Ids.New",
        providers: %{"uuid" => fn -> "PROVIDED-UUID" end},
        nested: %{}
      }
    })

    assert {:ok, %{id: "PROVIDED-UUID"}} = Tool.call("Ids.New", %{}, @caps)
  end

  test "the envelope is popped after the call returns" do
    register_uuid_tool()

    CapabilityStack.register_envelopes(%{
      "Ids.New" => %{tool: "Ids.New", providers: %{"uuid" => fn -> "X" end}, nested: %{}}
    })

    assert {:ok, _} = Tool.call("Ids.New", %{}, @caps)
    assert CapabilityStack.depth() == 0
    assert CapabilityStack.current() == nil
  end

  test "without a registered envelope, tool.call runs unchanged (live uuid)" do
    register_uuid_tool()

    assert {:ok, %{id: id}} = Tool.call("Ids.New", %{}, @caps)
    # A live v4 UUID, not a provider value.
    assert is_binary(id)
    assert id != "PROVIDED-UUID"
    assert String.length(id) == 36
  end

  test "a nested tool envelope controls a nested tool.call's effects" do
    # Outer tool calls the inner tool; the inner tool mints a uuid. The nested
    # envelope under Outer controls Inner's uuid provider.
    Tool.register("Inner.Make", %{}, fn _input -> {:ok, %{id: Nondeterminism.uuid()}} end)

    Tool.register("Outer.Run", %{}, fn _input ->
      caps = [%{kind: "tool.use", params: ["Inner.Make"]}]
      {:ok, inner} = Tool.call("Inner.Make", %{}, caps)
      {:ok, %{inner_id: inner.id}}
    end)

    CapabilityStack.register_envelopes(%{
      "Outer.Run" => %{
        tool: "Outer.Run",
        providers: %{},
        nested: %{
          "Inner.Make" => %{
            tool: "Inner.Make",
            providers: %{"uuid" => fn -> "NESTED-UUID" end},
            nested: %{}
          }
        }
      }
    })

    caps = [%{kind: "tool.use", params: ["Outer.Run"]}]
    assert {:ok, %{inner_id: "NESTED-UUID"}} = Tool.call("Outer.Run", %{}, caps)
    assert CapabilityStack.depth() == 0
  end

  describe "http.out provider" do
    @http_caps [%{kind: "http.out", params: []}]

    test "an http.out provider intercepts http.get; no network call" do
      provider = fn _req -> {:ok, %{status: 200, body: %{ok: true}, headers: %{}}} end

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"http.out" => provider}, nested: %{}},
          fn -> Http.get("https://api.example.com/x", @http_caps) end
        )

      assert {:ok, %{status: 200, body: %{ok: true}}} = result
    end

    test "the provider receives the request method and url" do
      provider = fn req ->
        {:ok, %{status: 201, body: %{seen: req.method <> " " <> req.url}, headers: %{}}}
      end

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"http.out" => provider}, nested: %{}},
          fn -> Http.get("https://api.example.com/y", @http_caps) end
        )

      assert {:ok, %{status: 201, body: %{seen: "GET https://api.example.com/y"}}} = result
    end

    test "a provider can return an HttpError (Err) the caller matches on" do
      provider = fn _req -> {:error, {:status, 400, "missing id header"}} end

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"http.out" => provider}, nested: %{}},
          fn -> Http.get("https://api.example.com/z", @http_caps) end
        )

      assert {:error, {:status, 400, "missing id header"}} = result
    end
  end

  describe "model (llm) provider" do
    @model_caps [%{kind: "model", params: ["anthropic", "claude-opus-4-8"]}]

    test "a model provider serves llm.chat from LlmResponse.text" do
      provider = fn _req -> {:ok, %{text: "PROVIDED ANSWER"}} end

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"model" => provider}, nested: %{}},
          fn -> Llm.chat("claude-opus-4-8", "sys", "hi", @model_caps) end
        )

      assert {:ok, "PROVIDED ANSWER"} = result
    end

    test "a model provider's text is decoded for llm.json against the schema" do
      provider = fn _req -> {:ok, %{text: ~s({"answer": "42"})}} end
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"model" => provider}, nested: %{}},
          fn -> Llm.json("claude-opus-4-8", "sys", "q", schema, @model_caps) end
        )

      assert {:ok, %{answer: "42"}} = result
    end

    test "the model provider receives an LlmRequest with model/system/prompt" do
      provider = fn req -> {:ok, %{text: "#{req.model}|#{req.system}|#{req.prompt}"}} end

      result =
        CapabilityStack.with_envelope(
          %{tool: "T", providers: %{"model" => provider}, nested: %{}},
          fn -> Llm.chat("claude-opus-4-8", "be terse", "hello", @model_caps) end
        )

      assert {:ok, "claude-opus-4-8|be terse|hello"} = result
    end
  end
end
