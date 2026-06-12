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

  # Resolve a handler function by route from __handlers__/0 metadata so the
  # tests survive handlers being added, removed, or reordered.
  defp call_handler(mod, route, request) do
    handler = Enum.find(mod.__handlers__(), &(&1.route == route)).handler
    apply(mod, handler, [request])
  end

  describe "skein_assistant.skein" do
    test "compiles successfully" do
      assert {:module, mod} = compile()
      assert is_atom(mod)
    end

    test "has 3 HTTP handlers" do
      {:module, mod} = compile()
      handlers = mod.__handlers__()
      assert length(handlers) == 3
      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "handler routes are correct" do
      {:module, mod} = compile()
      handlers = mod.__handlers__()
      routes = Enum.map(handlers, & &1.route)
      assert "/ask" in routes
      assert "/history/:session_id" in routes
      assert "/health" in routes
    end

    test "health handler returns ok as text" do
      {:module, mod} = compile()
      result = call_handler(mod, "/health", %{})
      assert {:respond_text, 200, "ok"} = result
    end

    test "ask handler calls LLM and responds" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} = compile()

      result =
        call_handler(mod, "/ask", %{
          params: %{session_id: "sess-1"},
          body: "How do I write a module?"
        })

      assert {:respond_json, 200, answer} = result
      assert answer != nil
    end

    test "history handler retrieves from memory" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} = compile()

      # First ask a question to populate memory
      call_handler(mod, "/ask", %{params: %{session_id: "sess-hist"}, body: "What is Skein?"})

      # Then get history — it contains the question and the answer
      result = call_handler(mod, "/history/:session_id", %{params: %{session_id: "sess-hist"}})
      assert {:respond_json, 200, history} = result
      assert history =~ "What is Skein?"
    end
  end
end
