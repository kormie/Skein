defmodule Skein.ExamplesTest do
  @moduledoc """
  Integration tests for the canonical Skein examples.

  Each test compiles a .skein file from the examples/ directory,
  loads the resulting module, and exercises its API.
  """
  use ExUnit.Case, async: false

  alias Skein.Compiler

  defp project_root do
    Path.join([__DIR__, "..", "..", "..", ".."]) |> Path.expand()
  end

  # ------------------------------------------------------------------
  # hello.skein
  # ------------------------------------------------------------------

  describe "hello.skein" do
    test "compiles and greet/1 works" do
      {:module, mod} = Compiler.compile_file(Path.join(project_root(), "examples/hello.skein"))
      assert mod.greet("World") == "Hello, World!"
    end

    test "compiles and add/2 works" do
      {:module, mod} = Compiler.compile_file(Path.join(project_root(), "examples/hello.skein"))
      assert mod.add(3, 4) == 7
    end

    test "compiles and classify/1 works" do
      {:module, mod} = Compiler.compile_file(Path.join(project_root(), "examples/hello.skein"))
      assert mod.classify(5) == "positive"
      assert mod.classify(-1) == "non-positive"
    end
  end

  # ------------------------------------------------------------------
  # hello_http.skein
  # ------------------------------------------------------------------

  describe "hello_http.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      assert is_atom(mod)
    end

    test "has handler metadata" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 5

      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "health handler returns ok as text" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      result = mod.__handler_0__(%{})
      assert {:respond_text, 200, "ok"} = result
    end

    test "greet handler is callable" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      result = mod.__handler_1__(%{params: %{name: "World"}})
      assert {:respond_json, 200, "hello"} = result
    end

    test "echo handler returns received" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      result = mod.__handler_2__(%{body: "test data"})
      assert {:respond_json, 200, "received"} = result
    end

    test "page handler returns HTML" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/hello_http.skein"))

      result = mod.__handler_4__(%{})
      assert {:respond_html, 200, "<h1>Hello from Skein</h1>"} = result
    end
  end

  # ------------------------------------------------------------------
  # queue_worker.skein
  # ------------------------------------------------------------------

  describe "queue_worker.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      assert is_atom(mod)
    end

    test "has mixed handler types" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 5

      sources = Enum.map(handlers, & &1.source)
      assert Enum.count(sources, &(&1 == :http)) == 1
      assert Enum.count(sources, &(&1 == :queue)) == 2
      assert Enum.count(sources, &(&1 == :schedule)) == 2
    end

    test "http health handler works" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "ok"} = result
    end

    test "queue handler processes messages" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      Skein.Runtime.Idempotent.reset_all()
      result = mod.__handler_1__(%{body: "job-data", id: "msg-001"})
      assert {:respond_json, 200, 2} = result
    end

    test "queue handler skips duplicate messages via idempotent" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      Skein.Runtime.Idempotent.reset_all()
      # First call succeeds
      result = mod.__handler_1__(%{body: "job-data", id: "msg-dup"})
      assert {:respond_json, 200, 2} = result

      # Second call with same id throws idempotent_skip
      assert catch_throw(mod.__handler_1__(%{body: "job-data", id: "msg-dup"})) ==
               {:idempotent_skip}
    end

    test "priority queue handler processes messages" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      result = mod.__handler_2__(%{body: "priority-job"})
      assert {:respond_json, 200, 4} = result
    end

    test "schedule handler returns cleanup" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      result = mod.__handler_3__(%{})
      assert {:respond_json, 200, "cleanup"} = result
    end

    test "daily schedule handler returns report" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      result = mod.__handler_4__(%{})
      assert {:respond_json, 200, "daily-report"} = result
    end

    test "handler metadata includes queue names" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      handlers = mod.__handlers__()

      queue_handlers = Enum.filter(handlers, &(&1.source == :queue))
      queue_names = Enum.map(queue_handlers, & &1.route)
      assert "jobs" in queue_names
      assert "jobs-priority" in queue_names
    end

    test "handler metadata includes cron expressions" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/queue_worker.skein"))

      handlers = mod.__handlers__()

      schedule_handlers = Enum.filter(handlers, &(&1.source == :schedule))
      crons = Enum.map(schedule_handlers, & &1.route)
      assert "*/5 * * * *" in crons
      assert "0 0 * * *" in crons
    end
  end

  # ------------------------------------------------------------------
  # refund_agent.skein — compilation test
  # ------------------------------------------------------------------

  describe "refund_agent.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/refund_agent.skein"))

      assert is_atom(mod)
    end

    test "has correct module attributes" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/refund_agent.skein"))

      info = mod.__info__(:module)
      assert info == mod
    end

    test "has Failed phase with suspend" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/refund_agent.skein"))

      phases = mod.__phases__()
      failed = Enum.find(phases, &(&1.name == :failed))
      assert failed != nil
      assert :review in failed.transitions

      # The Failed phase handler returns a suspend tuple
      result = mod.__phase_handler__(:failed, %{}, [])
      assert {:suspend, "Requires human review", %{}, []} = result
    end
  end

  # ------------------------------------------------------------------
  # incident_triage.skein — compilation test
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # supervisor_pool.skein
  # ------------------------------------------------------------------

  describe "supervisor_pool.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/supervisor_pool.skein"))

      assert is_atom(mod)
    end

    test "has supervisor metadata" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/supervisor_pool.skein"))

      sups = mod.__supervisors__()
      assert length(sups) == 2
      names = Enum.map(sups, & &1.name)
      assert "Main" in names
      assert "BatchSupervisor" in names
    end

    test "main supervisor has correct structure" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/supervisor_pool.skein"))

      main = Enum.find(mod.__supervisors__(), &(&1.name == "Main"))
      assert main.strategy == :one_for_one
      assert main.max_restarts == {10, 60}
      assert length(main.children) == 3
    end

    test "describe function handles enum variant matching" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/supervisor_pool.skein"))

      assert mod.describe({:order_placed, "abc", 100}) == "Order abc"
      assert mod.describe({:order_cancelled, "xyz", "changed mind"}) == "Cancelled xyz"
      assert mod.describe(:health_check) == "ping"
    end
  end

  # ------------------------------------------------------------------
  # stdlib_demo.skein
  # ------------------------------------------------------------------

  describe "stdlib_demo.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert is_atom(mod)
    end

    test "format_greeting trims and upcases name" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert mod.format_greeting("  alice  ") == "Hello, ALICE!"
      assert mod.format_greeting("Bob") == "Hello, BOB!"
    end

    test "classify_number clamps absolute values" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert mod.classify_number(-42) == "42"
      assert mod.classify_number(200) == "100"
      assert mod.classify_number(50) == "50"
    end

    test "safe_parse returns Result tuples" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert mod.safe_parse("42") == {:ok, 42}
      assert {:error, _} = mod.safe_parse("abc")
    end

    test "round_price rounds floats" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert mod.round_price(19.999, 2) == 20.0
      assert mod.round_price(3.14159, 3) == 3.142
    end

    test "normalize lowercases, trims, and deduplicates spaces" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/stdlib_demo.skein"))

      assert mod.normalize("  Hello  WORLD  ") == "hello world"
    end
  end

  # ------------------------------------------------------------------
  # incident_triage.skein — compilation test
  # ------------------------------------------------------------------

  describe "incident_triage.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/incident_triage.skein"))

      assert is_atom(mod)
    end

    test "has correct module attributes" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/incident_triage.skein"))

      info = mod.__info__(:module)
      assert info == mod
    end
  end

  # ------------------------------------------------------------------
  # pubsub_notifications.skein
  # ------------------------------------------------------------------

  describe "pubsub_notifications.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(
                 Path.join(project_root(), "examples/pubsub_notifications.skein")
               )

      assert is_atom(mod)
    end

    test "has mixed handler types including topic" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/pubsub_notifications.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 3

      sources = Enum.map(handlers, & &1.source)
      assert Enum.count(sources, &(&1 == :http)) == 1
      assert Enum.count(sources, &(&1 == :topic)) == 2
    end

    test "handler metadata includes topic names" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/pubsub_notifications.skein"))

      handlers = mod.__handlers__()

      topic_handlers = Enum.filter(handlers, &(&1.source == :topic))
      topic_names = Enum.map(topic_handlers, & &1.route)
      assert Enum.all?(topic_names, &(&1 == "order.events"))
    end

    test "http handler publishes and returns response" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/pubsub_notifications.skein"))

      result = mod.__handler_0__(%{body: "order-data"})
      assert {:respond_json, 200, "published"} = result
    end

    test "email topic handler returns response" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/pubsub_notifications.skein"))

      result = mod.__handler_1__(%{body: "order-event"})
      assert {:respond_json, 200, "email-sent"} = result
    end

    test "analytics topic handler returns response" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/pubsub_notifications.skein"))

      result = mod.__handler_2__(%{body: "order-event"})
      assert {:respond_json, 200, "analytics-recorded"} = result
    end
  end

  # ------------------------------------------------------------------
  # semantic_search.skein
  # ------------------------------------------------------------------

  describe "semantic_search.skein" do
    test "compiles successfully" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/semantic_search.skein"))

      assert is_atom(mod)
    end

    test "index function embeds and stores text" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/semantic_search.skein"))

      assert mod.index("doc_1", "The sky is blue") == "indexed"
    end

    test "search function uses embed and chat" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/semantic_search.skein"))

      # Index a document first so memory.get works
      mod.index("doc_1", "The sky is blue")

      assert {:ok, response} = mod.search("What color is the sky?")
      assert is_binary(response)
    end

    test "has HTTP handler metadata" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/semantic_search.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 2

      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end
  end
end
