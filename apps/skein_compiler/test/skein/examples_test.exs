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

  # ------------------------------------------------------------------
  # background_tasks.skein
  # ------------------------------------------------------------------

  describe "background_tasks.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/background_tasks.skein"))

      assert is_atom(mod)
    end

    test "has handler metadata with correct sources" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/background_tasks.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 5

      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "health handler returns ok" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/background_tasks.skein"))

      # The last handler (index 4) is GET /health
      result = mod.__handler_4__(%{})
      assert {:respond_json, 200, "ok"} = result
    end
  end

  # ------------------------------------------------------------------
  # market_research_agent.skein
  # ------------------------------------------------------------------

  describe "market_research_agent.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(
                 Path.join(project_root(), "examples/market_research/agent.skein")
               )

      assert is_atom(mod)
    end

    test "has correct phase definitions" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/agent.skein")
        )

      phases = mod.__phases__()
      phase_names = Enum.map(phases, & &1.name)
      assert :briefing in phase_names
      assert :gathering in phase_names
      assert :analyzing in phase_names
      assert :reporting in phase_names
      assert :complete in phase_names
      assert length(phases) == 5
    end

    test "phase transitions are correct" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/agent.skein")
        )

      phases = mod.__phases__()

      briefing = Enum.find(phases, &(&1.name == :briefing))
      assert :gathering in briefing.transitions

      gathering = Enum.find(phases, &(&1.name == :gathering))
      assert :analyzing in gathering.transitions
      assert :briefing in gathering.transitions

      analyzing = Enum.find(phases, &(&1.name == :analyzing))
      assert :gathering in analyzing.transitions
      assert :reporting in analyzing.transitions

      reporting = Enum.find(phases, &(&1.name == :reporting))
      assert :complete in reporting.transitions

      complete = Enum.find(phases, &(&1.name == :complete))
      assert complete.transitions == []
    end

    test "Complete phase handler calls stop" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/agent.skein")
        )

      result = mod.__phase_handler__(:complete, %{}, [])
      assert {:stop, %{}, []} = result
    end

    test "has all phase handlers" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/agent.skein")
        )

      phases = mod.__phases__()
      phase_names = Enum.map(phases, & &1.name)

      # Each phase should have a handler (no E0032 error)
      for name <- phase_names do
        assert is_function(Function.capture(mod, :__phase_handler__, 3)),
               "Missing phase handler for #{name}"
      end
    end
  end

  # ------------------------------------------------------------------
  # audit_log.skein
  # ------------------------------------------------------------------

  describe "audit_log.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(Path.join(project_root(), "examples/audit_log.skein"))

      assert is_atom(mod)
    end

    test "has handler metadata" do
      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/audit_log.skein"))

      handlers = mod.__handlers__()
      assert length(handlers) == 4

      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "login handler logs event and responds" do
      Skein.Runtime.EventLog.reset_all()

      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/audit_log.skein"))

      result = mod.__handler_0__(%{user: "alice"})
      assert {:respond_json, 200, "logged-in"} = result

      events = Skein.Runtime.EventLog.all()
      login_events = Enum.filter(events, &(&1.event == "user.login"))
      assert length(login_events) >= 1

      Skein.Runtime.EventLog.reset_all()
    end

    test "health handler returns ok without logging" do
      Skein.Runtime.EventLog.reset_all()

      {:module, mod} =
        Compiler.compile_file(Path.join(project_root(), "examples/audit_log.skein"))

      result = mod.__handler_3__(%{})
      assert {:respond_json, 200, "ok"} = result

      Skein.Runtime.EventLog.reset_all()
    end
  end

  # ------------------------------------------------------------------
  # market_research/api.skein
  # ------------------------------------------------------------------

  describe "market_research/api.skein" do
    test "compiles successfully" do
      assert {:module, mod} =
               Compiler.compile_file(
                 Path.join(project_root(), "examples/market_research/api.skein")
               )

      assert is_atom(mod)
    end

    test "has four HTTP handlers" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      handlers = mod.__handlers__()
      assert length(handlers) == 4

      sources = Enum.map(handlers, & &1.source)
      assert Enum.all?(sources, &(&1 == :http))
    end

    test "has correct routes" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      handlers = mod.__handlers__()
      routes = Enum.map(handlers, &{&1.method, &1.route})

      assert {:post, "/research/start"} in routes
      assert {:get, "/research/status"} in routes
      assert {:post, "/research/resume"} in routes
      assert {:get, "/research/report"} in routes
    end

    test "start handler parses typed JSON body" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      # Build a request with raw JSON body string
      req = %{body: ~s({"topic":"AI chips","industry":"semiconductors","focus_areas":"market share"})}
      result = mod.__handler_0__(req)
      assert {:respond_json, 201, body} = result
      assert is_map(body)
      assert body["topic"] == "AI chips"
    end

    test "status handler returns placeholder" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      result = mod.__handler_1__(%{})
      assert {:respond_json, 200, "status_placeholder"} = result
    end

    test "resume handler parses typed JSON body" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      req = %{body: ~s({"refined_topic":"AI chips for edge computing"})}
      result = mod.__handler_2__(req)
      assert {:respond_json, 200, body} = result
      assert is_map(body)
      assert body["refined_topic"] == "AI chips for edge computing"
    end

    test "report handler returns placeholder" do
      {:module, mod} =
        Compiler.compile_file(
          Path.join(project_root(), "examples/market_research/api.skein")
        )

      result = mod.__handler_3__(%{})
      assert {:respond_json, 200, "report_placeholder"} = result
    end
  end
end
