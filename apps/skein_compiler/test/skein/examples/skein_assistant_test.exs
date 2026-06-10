defmodule Skein.Examples.SkeinAssistantTest do
  @moduledoc """
  Integration tests for examples/skein_assistant.skein
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  defp project_root do
    Path.join([__DIR__, "..", "..", "..", "..", ".."]) |> Path.expand()
  end

  defp compile do
    Compiler.compile_file(Path.join(project_root(), "examples/skein_assistant.skein"))
  end

  describe "skein_assistant.skein" do
    test "compiles successfully" do
      assert {:module, mod} = compile()
      assert is_atom(mod)
    end

    test "has 4 HTTP handlers" do
      {:module, mod} = compile()
      handlers = mod.__handlers__()
      assert length(handlers) == 4
      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "handler routes are correct" do
      {:module, mod} = compile()
      handlers = mod.__handlers__()
      routes = Enum.map(handlers, & &1.route)
      assert "/ask" in routes
      assert "/compile" in routes
      assert "/history/:session_id" in routes
      assert "/health" in routes
    end

    test "health handler returns ok as text" do
      {:module, mod} = compile()
      result = mod.__handler_3__(%{})
      assert {:respond_text, 200, "ok"} = result
    end

    test "compile handler returns response" do
      {:module, mod} = compile()
      result = mod.__handler_1__(%{body: "module Foo { fn bar() -> String { \"hi\" } }"})
      assert {:respond_json, 200, "compile-check-complete"} = result
    end

    test "ask handler calls LLM and responds" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} = compile()

      result =
        mod.__handler_0__(%{params: %{session_id: "sess-1"}, body: "How do I write a module?"})

      assert {:respond_json, 200, answer} = result
      assert answer != nil
    end

    test "history handler retrieves from memory" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} = compile()

      # First ask a question to populate memory
      mod.__handler_0__(%{params: %{session_id: "sess-hist"}, body: "What is Skein?"})

      # Then get history
      result = mod.__handler_2__(%{params: %{session_id: "sess-hist"}})
      assert {:respond_json, 200, _history} = result
    end
  end
end
