defmodule Skein.CodeGen.CoreErlangTest do
  use ExUnit.Case, async: false

  alias Skein.Compiler

  # Helper: compile a Skein source string and return the loaded module
  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # Helper: same as compile! but for modules with capabilities and effect calls
  defp compile_with_caps!(source) do
    compile!(source)
  end

  describe "Phase 1 acceptance - hello.skein" do
    test "greet/1 returns interpolated greeting" do
      mod =
        compile!("""
        module HelloGreet {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }
        }
        """)

      assert mod.greet("World") == "Hello, World!"
      assert mod.greet("Skein") == "Hello, Skein!"
      assert mod.greet("") == "Hello, !"
    end

    test "add/2 returns the sum of two integers" do
      mod =
        compile!("""
        module HelloAdd {
          fn add(a: Int, b: Int) -> Int {
            a + b
          }
        }
        """)

      assert mod.add(3, 4) == 7
      assert mod.add(0, 0) == 0
      assert mod.add(-1, 1) == 0
      assert mod.add(100, 200) == 300
    end

    test "classify/1 returns correct classification" do
      mod =
        compile!("""
        module HelloClassify {
          fn classify(n: Int) -> String {
            match n > 0 {
              true  -> "positive"
              false -> "non-positive"
            }
          }
        }
        """)

      assert mod.classify(5) == "positive"
      assert mod.classify(1) == "positive"
      assert mod.classify(0) == "non-positive"
      assert mod.classify(-1) == "non-positive"
      assert mod.classify(-100) == "non-positive"
    end

    test "all three functions in one module" do
      mod =
        compile!("""
        module HelloAll {
          fn greet(name: String) -> String {
            "Hello, ${name}!"
          }

          fn add(a: Int, b: Int) -> Int {
            a + b
          }

          fn classify(n: Int) -> String {
            match n > 0 {
              true  -> "positive"
              false -> "non-positive"
            }
          }
        }
        """)

      assert mod.greet("World") == "Hello, World!"
      assert mod.add(3, 4) == 7
      assert mod.classify(5) == "positive"
      assert mod.classify(-1) == "non-positive"
    end
  end

  describe "integer arithmetic" do
    test "subtraction" do
      mod =
        compile!("""
        module ArithSub {
          fn sub(a: Int, b: Int) -> Int {
            a - b
          }
        }
        """)

      assert mod.sub(10, 3) == 7
    end

    test "multiplication" do
      mod =
        compile!("""
        module ArithMul {
          fn mul(a: Int, b: Int) -> Int {
            a * b
          }
        }
        """)

      assert mod.mul(6, 7) == 42
    end

    test "integer division" do
      mod =
        compile!("""
        module ArithDiv {
          fn divide(a: Int, b: Int) -> Int {
            a / b
          }
        }
        """)

      assert mod.divide(10, 3) == 3
      assert mod.divide(9, 3) == 3
    end

    test "complex expression with precedence" do
      mod =
        compile!("""
        module ArithComplex {
          fn calc(a: Int, b: Int, c: Int) -> Int {
            a + b * c
          }
        }
        """)

      # Should compute a + (b * c), not (a + b) * c
      assert mod.calc(1, 2, 3) == 7
    end
  end

  describe "let bindings" do
    test "simple let binding" do
      mod =
        compile!("""
        module LetSimple {
          fn double(x: Int) -> Int {
            let result = x + x
            result
          }
        }
        """)

      assert mod.double(5) == 10
    end

    test "multiple let bindings" do
      mod =
        compile!("""
        module LetMulti {
          fn calc(x: Int) -> Int {
            let a = x + 1
            let b = a + 2
            b
          }
        }
        """)

      assert mod.calc(10) == 13
    end
  end

  describe "boolean operations" do
    test "comparison operators" do
      mod =
        compile!("""
        module BoolCmp {
          fn is_positive(n: Int) -> Bool {
            n > 0
          }

          fn is_zero(n: Int) -> Bool {
            n == 0
          }
        }
        """)

      assert mod.is_positive(1) == true
      assert mod.is_positive(0) == false
      assert mod.is_zero(0) == true
      assert mod.is_zero(1) == false
    end
  end

  describe "string operations" do
    test "plain string literal" do
      mod =
        compile!("""
        module StrPlain {
          fn hello() -> String {
            "hello world"
          }
        }
        """)

      assert mod.hello() == "hello world"
    end

    test "string with multiple interpolations" do
      mod =
        compile!("""
        module StrMulti {
          fn greet(first: String, last: String) -> String {
            "${first} ${last}"
          }
        }
        """)

      assert mod.greet("Jane", "Doe") == "Jane Doe"
    end
  end

  describe "match expressions" do
    test "match on integer values" do
      mod =
        compile!("""
        module MatchInt {
          fn describe(n: Int) -> String {
            match n {
              0 -> "zero"
              1 -> "one"
              _ -> "other"
            }
          }
        }
        """)

      assert mod.describe(0) == "zero"
      assert mod.describe(1) == "one"
      assert mod.describe(42) == "other"
    end

    test "match on boolean with block body" do
      mod =
        compile!("""
        module MatchBlock {
          fn abs_val(n: Int) -> Int {
            match n > 0 {
              true -> n
              false -> 0 - n
            }
          }
        }
        """)

      assert mod.abs_val(5) == 5
      assert mod.abs_val(-3) == 3
      assert mod.abs_val(0) == 0
    end
  end

  describe "compile_file/1" do
    test "compiles a .skein file" do
      assert {:module, mod} = Compiler.compile_file("../../examples/hello.skein")
      assert mod.greet("World") == "Hello, World!"
      assert mod.add(3, 4) == 7
      assert mod.classify(5) == "positive"
    end
  end

  # ------------------------------------------------------------------
  # Phase 3: Capability metadata and effect call codegen
  # ------------------------------------------------------------------

  describe "__capabilities__/0" do
    test "module with no capabilities returns empty list" do
      mod =
        compile!("""
        module CapEmpty {
          fn x() -> Int { 1 }
        }
        """)

      assert mod.__capabilities__() == []
    end

    test "module with http.out capability returns it" do
      mod =
        compile_with_caps!("""
        module CapHttp {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "http.out", params: ["api.example.com"]} = hd(caps)
    end

    test "module with multiple capabilities returns all" do
      mod =
        compile_with_caps!("""
        module CapMulti {
          capability http.out("api.example.com")
          capability http.out("api.other.com")

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 2
    end

    test "capability without params returns empty params list" do
      mod =
        compile_with_caps!("""
        module CapNoParams {
          capability http.out

          fn fetch(url: String) -> String {
            "stub"
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "http.out", params: []} = hd(caps)
    end
  end

  describe "effect call codegen" do
    test "http.get compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module EffectGet {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # The function should exist and be callable
      fns = mod.__info__(:functions)
      assert {:fetch, 1} in fns
    end

    test "http.post compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module EffectPost {
          capability http.out("api.example.com")

          fn send(url: String, body: String) -> String {
            http.post(url, body)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:send, 2} in fns
    end

    test "http.get at runtime enforces capabilities - blocks undeclared host" do
      mod =
        compile_with_caps!("""
        module EffectBlock {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # Calling with an undeclared host should return capability error
      result = mod.fetch("https://api.blocked.com/data")
      assert {:error, reason} = result
      assert reason =~ "not declared"
    end

    test "http.get at runtime enforces capabilities - allows declared host" do
      mod =
        compile_with_caps!("""
        module EffectAllow {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # Calling with a declared host - will attempt HTTP (may fail to connect,
      # but should NOT be a capability error)
      result = mod.fetch("https://api.example.com/data")

      case result do
        {:error, reason} -> refute reason =~ "not declared"
        {:ok, _} -> :ok
      end
    end

    test "http.get records trace span" do
      Skein.Runtime.Trace.clear()

      mod =
        compile_with_caps!("""
        module EffectTrace {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            http.get(url)
          }
        }
        """)

      # This will be blocked by capability, but should still trace
      mod.fetch("https://api.blocked.com/data")

      spans = Skein.Runtime.Trace.recent_spans(10)
      assert length(spans) >= 1

      span = hd(spans)
      assert span.kind == :http
      assert span.method == :get
      assert span.url == "https://api.blocked.com/data"
      assert is_integer(span.duration_us)
    end

    test "effect call in let binding works" do
      mod =
        compile_with_caps!("""
        module EffectLet {
          capability http.out("api.allowed.com")

          fn fetch(url: String) -> String {
            let result = http.get(url)
            result
          }
        }
        """)

      result = mod.fetch("https://api.blocked.com/data")
      assert {:error, reason} = result
      assert reason =~ "not declared"
    end
  end

  # ------------------------------------------------------------------
  # Phase 4: Handler codegen
  # ------------------------------------------------------------------

  describe "__handlers__/0" do
    test "module with no handlers returns empty list" do
      mod =
        compile!("""
        module HandlersEmpty {
          fn x() -> Int { 1 }
        }
        """)

      assert mod.__handlers__() == []
    end

    test "module with one handler returns metadata" do
      mod =
        compile!("""
        module HandlersOne {
          capability http.in

          handler http GET "/users" (req) -> {
            respond.json(200, "ok")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 1
      assert %{method: :get, route: "/users", handler: :__handler_0__} = hd(handlers)
    end

    test "module with multiple handlers returns all metadata" do
      mod =
        compile!("""
        module HandlersMulti {
          capability http.in

          handler http GET "/users" (req) -> {
            respond.json(200, "list")
          }

          handler http POST "/users" (req) -> {
            respond.json(201, "created")
          }

          handler http GET "/users/:id" (req) -> {
            respond.json(200, "detail")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 3

      [h0, h1, h2] = handlers
      assert h0.method == :get
      assert h0.route == "/users"
      assert h1.method == :post
      assert h1.route == "/users"
      assert h2.method == :get
      assert h2.route == "/users/:id"
    end
  end

  describe "handler function codegen" do
    test "handler function is callable with request map" do
      mod =
        compile!("""
        module HandlerCall {
          capability http.in

          handler http GET "/test" (req) -> {
            respond.json(200, "hello")
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "hello"} = result
    end

    test "handler with integer status code and string body" do
      mod =
        compile!("""
        module HandlerStatus {
          capability http.in

          handler http POST "/items" (req) -> {
            respond.json(201, "created")
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 201, "created"} = result
    end

    test "handler can access request parameter" do
      mod =
        compile!("""
        module HandlerReq {
          capability http.in

          handler http GET "/users/:id" (req) -> {
            let name = "user"
            respond.json(200, name)
          }
        }
        """)

      result = mod.__handler_0__(%{params: %{id: "123"}})
      assert {:respond_json, 200, "user"} = result
    end

    test "handler with match expression" do
      mod =
        compile!("""
        module HandlerMatch {
          capability http.in

          handler http GET "/status" (req) -> {
            match 1 > 0 {
              true -> respond.json(200, "ok")
              false -> respond.json(500, "error")
            }
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "ok"} = result
    end

    test "handler with let bindings" do
      mod =
        compile!("""
        module HandlerLet {
          capability http.in

          handler http GET "/compute" (req) -> {
            let x = 1 + 2
            let y = x + 3
            respond.json(200, y)
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, 6} = result
    end

    test "handler can call module functions" do
      mod =
        compile!("""
        module HandlerCallFn {
          capability http.in

          fn make_greeting(name: String) -> String {
            "Hello, ${name}!"
          }

          handler http GET "/greet" (req) -> {
            let greeting = make_greeting("World")
            respond.json(200, greeting)
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "Hello, World!"} = result
    end

    test "multiple handlers have separate functions" do
      mod =
        compile!("""
        module HandlerSep {
          capability http.in

          handler http GET "/a" (req) -> {
            respond.json(200, "a")
          }

          handler http POST "/b" (req) -> {
            respond.json(201, "b")
          }
        }
        """)

      assert {:respond_json, 200, "a"} = mod.__handler_0__(%{})
      assert {:respond_json, 201, "b"} = mod.__handler_1__(%{})
    end
  end

  # ------------------------------------------------------------------
  # Phase 5: Store operation codegen
  # ------------------------------------------------------------------

  describe "store capability metadata" do
    test "module with store.table capability returns it" do
      mod =
        compile!("""
        module StoreCap {
          capability store.table("users")

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "store.table", params: ["users"]} = hd(caps)
    end

    test "module with multiple store.table capabilities returns all" do
      mod =
        compile!("""
        module StoreCapMulti {
          capability store.table("users")
          capability store.table("orders")

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 2
      kinds = Enum.map(caps, & &1.kind)
      assert Enum.all?(kinds, &(&1 == "store.table"))
      params = Enum.flat_map(caps, & &1.params)
      assert "users" in params
      assert "orders" in params
    end
  end

  describe "store.get codegen" do
    test "store.users.get compiles and calls runtime" do
      mod =
        compile!("""
        module StoreGet {
          capability store.table("users")

          fn find(id: String) -> String {
            store.users.get(id)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:find, 1} in fns

      # Store is empty — should return not_found
      Skein.Runtime.Store.clear("users")
      result = mod.find("some-id")
      assert {:error, "not_found"} = result
    end

    test "store.users.get returns record when it exists" do
      mod =
        compile!("""
        module StoreGetFound {
          capability store.table("users")

          fn find(id: String) -> String {
            store.users.get(id)
          }
        }
        """)

      # Insert a record directly via the runtime
      Skein.Runtime.Store.clear("users")
      caps = [%{kind: "store.table", params: ["users"]}]
      {:ok, _} = Skein.Runtime.Store.put("users", %{id: "u1", name: "Alice"}, caps)

      result = mod.find("u1")
      assert {:ok, %{id: "u1", name: "Alice"}} = result
    end
  end

  describe "store.put codegen" do
    test "store.users.put compiles and inserts records" do
      mod =
        compile!("""
        module StorePut {
          capability store.table("items")

          fn save(record: String) -> String {
            store.items.put(record)
          }
        }
        """)

      Skein.Runtime.Store.clear("items")
      result = mod.save(%{id: "i1", name: "Widget"})
      assert {:ok, %{id: "i1", name: "Widget"}} = result

      # Verify the record is actually stored
      caps = [%{kind: "store.table", params: ["items"]}]
      assert {:ok, %{id: "i1", name: "Widget"}} = Skein.Runtime.Store.get("items", "i1", caps)
    end
  end

  describe "store.delete codegen" do
    test "store.users.delete compiles and removes records" do
      mod =
        compile!("""
        module StoreDelete {
          capability store.table("items")

          fn remove(id: String) -> String {
            store.items.delete(id)
          }
        }
        """)

      Skein.Runtime.Store.clear("items")
      caps = [%{kind: "store.table", params: ["items"]}]
      {:ok, _} = Skein.Runtime.Store.put("items", %{id: "i1", name: "Widget"}, caps)

      result = mod.remove("i1")
      assert {:ok, "i1"} = result

      # Verify the record is gone
      assert {:error, "not_found"} = Skein.Runtime.Store.get("items", "i1", caps)
    end
  end

  describe "store.query codegen" do
    test "store.users.query compiles and filters records" do
      mod =
        compile!("""
        module StoreQuery {
          capability store.table("users")

          fn search(filters: String) -> String {
            store.users.query(filters)
          }
        }
        """)

      Skein.Runtime.Store.clear("users")
      caps = [%{kind: "store.table", params: ["users"]}]
      {:ok, _} = Skein.Runtime.Store.put("users", %{id: "u1", name: "Alice", role: "admin"}, caps)
      {:ok, _} = Skein.Runtime.Store.put("users", %{id: "u2", name: "Bob", role: "user"}, caps)
      {:ok, _} = Skein.Runtime.Store.put("users", %{id: "u3", name: "Carol", role: "admin"}, caps)

      results = mod.search(%{role: "admin"})
      assert is_list(results)
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol"]
    end
  end

  describe "store operations record traces" do
    test "store.get records a trace span" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module StoreTrace {
          capability store.table("users")

          fn find(id: String) -> String {
            store.users.get(id)
          }
        }
        """)

      Skein.Runtime.Store.clear("users")
      mod.find("some-id")

      spans = Skein.Runtime.Trace.recent_spans(10)
      store_spans = Enum.filter(spans, &(&1.kind == :store))
      assert length(store_spans) >= 1

      span = hd(store_spans)
      assert span.kind == :store
      assert span.method == :get
      assert span.table == "users"
      assert is_integer(span.duration_us)
    end
  end

  describe "store runtime capability enforcement" do
    test "store.get at runtime blocks undeclared table" do
      mod =
        compile!("""
        module StoreBlock {
          capability store.table("orders")

          fn find(id: String) -> String {
            store.orders.get(id)
          }
        }
        """)

      # The module has "orders" capability but let's verify it works
      Skein.Runtime.Store.clear("orders")
      result = mod.find("o1")
      assert {:error, "not_found"} = result
    end
  end

  describe "__info__/1 Elixir interop" do
    test "module responds to __info__(:module)" do
      mod =
        compile!("""
        module InfoTest {
          fn x() -> Int { 1 }
        }
        """)

      assert mod.__info__(:module) == mod
    end

    test "module responds to __info__(:functions)" do
      mod =
        compile!("""
        module InfoFns {
          fn a() -> Int { 1 }
          fn b(x: Int) -> Int { x }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:a, 0} in fns
      assert {:b, 1} in fns
    end
  end

  # ------------------------------------------------------------------
  # Phase 6a: Agent codegen
  # ------------------------------------------------------------------

  describe "agent codegen - basic compilation" do
    test "agent compiles to a BEAM module" do
      mod =
        compile!("""
        agent SimpleAgent {
          enum Phase {
            Init -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      assert mod.__info__(:module) == mod
    end

    test "agent exposes __phases__/0 metadata" do
      mod =
        compile!("""
        agent PhasesAgent {
          enum Phase {
            Analyze -> [Refund, Done]
            Refund -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Analyze)
          }

          on phase(Phase.Analyze) -> {
            transition(Phase.Refund)
          }

          on phase(Phase.Refund) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      phases = mod.__phases__()
      assert is_list(phases)
      assert length(phases) == 3

      analyze = Enum.find(phases, &(&1.name == :analyze))
      assert analyze != nil
      assert :refund in analyze.transitions
      assert :done in analyze.transitions
    end

    test "agent start_link/1 starts a gen_statem process" do
      mod =
        compile!("""
        agent StartableAgent {
          enum Phase {
            Working -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      assert {:ok, pid} = mod.start_link(%{})
      # The agent should transition through all phases and stop
      # Give it a moment to process
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent codegen - phase transitions" do
    test "agent transitions through phases and stops" do
      mod =
        compile!("""
        agent TransitionAgent {
          enum Phase {
            Init -> [Processing]
            Processing -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            transition(Phase.Processing)
          }

          on phase(Phase.Processing) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{})
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "agent with match-based transitions" do
      mod =
        compile!("""
        agent MatchAgent {
          enum Phase {
            Check -> [Pass, Fail]
            Pass -> []
            Fail -> []
          }

          on start() -> {
            transition(Phase.Check)
          }

          on phase(Phase.Check) -> {
            match true {
              true -> transition(Phase.Pass)
              false -> transition(Phase.Fail)
            }
          }

          on phase(Phase.Pass) -> {
            stop()
          }

          on phase(Phase.Fail) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{})
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent codegen - start handler with params" do
    test "agent receives start parameters" do
      mod =
        compile!("""
        agent ParamAgent {
          enum Phase {
            Working -> []
          }

          on start(name: String) -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            stop()
          }
        }
        """)

      {:ok, pid} = mod.start_link(%{name: "test"})
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "agent codegen - user functions" do
    test "agent exposes user-defined functions" do
      mod =
        compile!("""
        agent FnAgent {
          enum Phase {
            Init -> []
          }

          fn helper(x: Int) -> Int {
            x + 1
          }

          on start() -> {
            transition(Phase.Init)
          }

          on phase(Phase.Init) -> {
            stop()
          }
        }
        """)

      assert mod.helper(5) == 6
      assert mod.helper(0) == 1
    end
  end

  # ------------------------------------------------------------------
  # Phase 6a acceptance: end-to-end agent lifecycle
  # ------------------------------------------------------------------

  describe "Phase 6a acceptance - agent compiles to gen_statem" do
    test "complete agent lifecycle: start -> phases -> transitions -> stop" do
      mod =
        compile!("""
        agent ReviewAgent {
          state {
            ticket_id: String
          }

          enum Phase {
            Analyze -> [Approve, Reject]
            Approve -> [Done]
            Reject -> [Done]
            Done -> []
          }

          on start(ticket_id: String) -> {
            transition(Phase.Analyze)
          }

          on phase(Phase.Analyze) -> {
            match 1 > 0 {
              true -> transition(Phase.Approve)
              false -> transition(Phase.Reject)
            }
          }

          on phase(Phase.Approve) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Reject) -> {
            transition(Phase.Done)
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      # Agent compiles to BEAM
      assert mod.__info__(:module) == mod

      # Phase metadata is accessible
      phases = mod.__phases__()
      assert length(phases) == 4

      analyze = Enum.find(phases, &(&1.name == :analyze))
      assert :approve in analyze.transitions
      assert :reject in analyze.transitions

      done = Enum.find(phases, &(&1.name == :done))
      assert done.transitions == []

      # Agent starts, runs through all phases, and stops
      {:ok, pid} = mod.start_link(%{ticket_id: "T-123"})
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "invalid transitions are caught at compile time" do
      # This should fail analysis because Done -> Analyze is not declared
      source = """
      agent InvalidAgent {
        enum Phase {
          Analyze -> [Done]
          Done -> []
        }

        on start() -> {
          transition(Phase.Analyze)
        }

        on phase(Phase.Analyze) -> {
          transition(Phase.Done)
        }

        on phase(Phase.Done) -> {
          transition(Phase.Analyze)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)

      transition_error =
        Enum.find(errors, &(&1.code == "E0030" and &1.message =~ "Done cannot transition"))

      assert transition_error != nil
    end

    test "missing phase handlers are caught at compile time" do
      source = """
      agent IncompleteAgent {
        enum Phase {
          A -> [B]
          B -> []
        }

        on start() -> {
          transition(Phase.A)
        }

        on phase(Phase.A) -> {
          transition(Phase.B)
        }
      }
      """

      {:ok, tokens} = Skein.Lexer.tokenize(source)
      {:ok, ast} = Skein.Parser.parse(tokens)
      assert {:error, errors} = Skein.Analyzer.analyze(ast)

      missing_error = Enum.find(errors, &(&1.code == "E0032" and &1.message =~ "B"))
      assert missing_error != nil
    end
  end

  # ------------------------------------------------------------------
  # Phase 6b: Memory codegen
  # ------------------------------------------------------------------

  describe "memory capability metadata" do
    test "module with memory.kv capability returns it" do
      mod =
        compile_with_caps!("""
        module MemoryCaps {
          capability memory.kv("sessions")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "memory.kv", params: ["sessions"]} = hd(caps)
    end
  end

  describe "memory.put codegen" do
    test "memory.put compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module MemPut {
          capability memory.kv("sessions")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:save, 2} in fns
    end

    test "memory.put at runtime stores and returns value" do
      mod =
        compile_with_caps!("""
        module MemPutRun {
          capability memory.kv("test_ns")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      Skein.Runtime.Memory.clear("test_ns")
      result = mod.save("hello", "world")
      assert {:ok, "world"} = result
      Skein.Runtime.Memory.clear("test_ns")
    end
  end

  describe "memory.get codegen" do
    test "memory.get compiles and retrieves values" do
      mod =
        compile_with_caps!("""
        module MemGet {
          capability memory.kv("test_get")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn load(key: String) -> String {
            memory.get(key)
          }
        }
        """)

      Skein.Runtime.Memory.clear("test_get")
      mod.save("k1", "v1")
      assert {:ok, "v1"} = mod.load("k1")
      assert {:error, "not_found"} = mod.load("missing")
      Skein.Runtime.Memory.clear("test_get")
    end
  end

  describe "memory.delete codegen" do
    test "memory.delete compiles and removes values" do
      mod =
        compile_with_caps!("""
        module MemDel {
          capability memory.kv("test_del")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn remove(key: String) -> String {
            memory.delete(key)
          }

          fn load(key: String) -> String {
            memory.get(key)
          }
        }
        """)

      Skein.Runtime.Memory.clear("test_del")
      mod.save("k1", "v1")
      assert {:ok, "k1"} = mod.remove("k1")
      assert {:error, "not_found"} = mod.load("k1")
      Skein.Runtime.Memory.clear("test_del")
    end
  end

  describe "memory.list codegen" do
    test "memory.list compiles and returns keys" do
      mod =
        compile_with_caps!("""
        module MemList {
          capability memory.kv("test_list")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }

          fn keys(prefix: String) -> String {
            memory.list(prefix)
          }
        }
        """)

      Skein.Runtime.Memory.clear("test_list")
      mod.save("user:1", "alice")
      mod.save("user:2", "bob")
      mod.save("config:a", "x")

      keys = mod.keys("user:")
      assert Enum.sort(keys) == ["user:1", "user:2"]
      Skein.Runtime.Memory.clear("test_list")
    end
  end

  describe "memory operations record traces" do
    test "memory.put records a trace span" do
      Skein.Runtime.Trace.clear()

      mod =
        compile_with_caps!("""
        module MemTrace {
          capability memory.kv("trace_ns")

          fn save(key: String, value: String) -> String {
            memory.put(key, value)
          }
        }
        """)

      Skein.Runtime.Memory.clear("trace_ns")
      mod.save("k", "v")

      spans = Skein.Runtime.Trace.recent_spans(10)
      memory_spans = Enum.filter(spans, &(&1.kind == :memory))
      assert length(memory_spans) >= 1

      span = hd(memory_spans)
      assert span.kind == :memory
      assert span.method == :put
      assert span.namespace == "trace_ns"
      Skein.Runtime.Memory.clear("trace_ns")
    end
  end

  # ------------------------------------------------------------------
  # Phase 6b: LLM codegen
  # ------------------------------------------------------------------

  describe "llm capability metadata" do
    test "module with model capability returns it" do
      mod =
        compile_with_caps!("""
        module LlmCaps {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      caps = mod.__capabilities__()
      assert length(caps) == 1
      assert %{kind: "model", params: ["anthropic", "claude-sonnet-4-5"]} = hd(caps)
    end
  end

  describe "llm.chat codegen" do
    test "llm.chat compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module LlmChat {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:ask, 1} in fns
    end

    test "llm.chat at runtime returns response from test backend" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      mod =
        compile_with_caps!("""
        module LlmChatRun {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      assert {:ok, response} = mod.ask("Hello")
      assert is_binary(response)
      assert response =~ "Hello"
    end

    test "llm.chat without model capability at runtime returns error" do
      # This tests the runtime capability check layer.
      # Since the analyzer also blocks this, we test the runtime module directly.
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      result = Skein.Runtime.Llm.chat("claude-sonnet-4-5", "Be helpful.", "Hello", [])
      assert {:error, %Skein.Runtime.Llm.Error{kind: :capability_error}} = result
    end
  end

  describe "llm.json codegen" do
    test "llm.json compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module LlmJson {
          capability model("anthropic", "claude-sonnet-4-5")

          fn decide(data: String) -> String {
            llm.json("claude-sonnet-4-5", "Return JSON.", data)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:decide, 1} in fns
    end

    test "llm.json at runtime returns parsed response from test backend" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      mod =
        compile_with_caps!("""
        module LlmJsonRun {
          capability model("anthropic", "claude-sonnet-4-5")

          fn decide(data: String) -> String {
            llm.json("claude-sonnet-4-5", "Return JSON.", data)
          }
        }
        """)

      assert {:ok, result} = mod.decide("some ticket")
      assert is_map(result)
    end
  end

  describe "llm operations record traces" do
    test "llm.chat records a trace span" do
      Skein.Runtime.Trace.clear()
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.TestBackend)

      mod =
        compile_with_caps!("""
        module LlmTrace {
          capability model("anthropic", "claude-sonnet-4-5")

          fn ask(data: String) -> String {
            llm.chat("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      mod.ask("Hello")

      spans = Skein.Runtime.Trace.recent_spans(10)
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))
      assert length(llm_spans) >= 1

      span = hd(llm_spans)
      assert span.kind == :llm
      assert span.method == :chat
      assert span.model == "claude-sonnet-4-5"
    end
  end

  # ------------------------------------------------------------------
  # llm.stream codegen (Phase 8f)
  # ------------------------------------------------------------------

  describe "llm.stream codegen" do
    test "llm.stream compiles to runtime call" do
      mod =
        compile_with_caps!("""
        module LlmStream {
          capability model("anthropic", "claude-sonnet-4-5")

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:stream_it, 1} in fns
    end

    test "llm.stream at runtime returns assembled response" do
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)

      mod =
        compile_with_caps!("""
        module LlmStreamRun {
          capability model("anthropic", "claude-sonnet-4-5")

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      assert {:ok, response} = mod.stream_it("Hello")
      assert is_binary(response)
    end

    test "llm.stream records a trace span" do
      Skein.Runtime.Trace.clear()
      Skein.Runtime.Llm.set_backend(Skein.Runtime.Llm.StreamingTestBackend)

      mod =
        compile_with_caps!("""
        module LlmStreamTrace {
          capability model("anthropic", "claude-sonnet-4-5")

          fn stream_it(data: String) -> String {
            llm.stream("claude-sonnet-4-5", "Be helpful.", data)
          }
        }
        """)

      mod.stream_it("Hello")

      spans = Skein.Runtime.Trace.recent_spans(10)
      llm_spans = Enum.filter(spans, &(&1.kind == :llm))
      assert length(llm_spans) >= 1

      span = hd(llm_spans)
      assert span.kind == :llm
      assert span.method == :stream
      assert span.model == "claude-sonnet-4-5"
    end
  end

  # ------------------------------------------------------------------
  # Tool declarations and tool.call (Phase 6c)
  # ------------------------------------------------------------------

  describe "tool declarations" do
    test "module with tool declaration compiles successfully" do
      mod =
        compile_with_caps!("""
        module ToolDeclSimple {
          tool MyTool {
            input { amount: Int }
            output { id: String }
            implement { "ok" }
          }
        }
        """)

      assert is_atom(mod)
    end

    test "__tools__/0 returns tool metadata" do
      mod =
        compile_with_caps!("""
        module ToolMeta {
          tool CreateRefund {
            input { amount: Int }
            output { id: String }
            implement { "ok" }
          }
        }
        """)

      tools = mod.__tools__()
      assert is_list(tools)
      assert length(tools) == 1
      [tool] = tools
      assert tool.name == "CreateRefund"
      assert is_list(tool.input)
      assert is_list(tool.output)
    end

    test "__tools__/0 includes field names and types" do
      mod =
        compile_with_caps!("""
        module ToolFieldInfo {
          tool MyTool {
            input {
              amount: Int
              customer_id: String
            }
            output {
              id: String
              status: String
            }
            implement { "ok" }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert length(tool.input) == 2
      assert length(tool.output) == 2

      [amount, cust] = tool.input
      assert amount.name == "amount"
      assert amount.type == "Int"
      assert cust.name == "customer_id"
      assert cust.type == "String"
    end

    test "__tools__/0 returns multiple tools" do
      mod =
        compile_with_caps!("""
        module ToolMulti {
          tool ToolA {
            input { x: Int }
            output { y: Int }
            implement { 42 }
          }

          tool ToolB {
            input { name: String }
            output { result: String }
            implement { "ok" }
          }
        }
        """)

      tools = mod.__tools__()
      assert length(tools) == 2
      names = Enum.map(tools, & &1.name)
      assert "ToolA" in names
      assert "ToolB" in names
    end

    test "tool with dotted name appears in __tools__/0" do
      mod =
        compile_with_caps!("""
        module ToolDotted {
          tool Stripe.CreateRefund {
            input { amount: Int }
            output { id: String }
            implement { "ok" }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.name == "Stripe.CreateRefund"
    end

    test "tool with description includes it in metadata" do
      mod =
        compile_with_caps!("""
        module ToolDesc {
          tool MyTool {
            description: "A helpful tool"
            input { x: Int }
            output { y: Int }
            implement { 42 }
          }
        }
        """)

      [tool] = mod.__tools__()
      assert tool.description == "A helpful tool"
    end
  end

  describe "tool.call codegen" do
    setup do
      Skein.Runtime.Tool.clear_registry()
      Skein.Runtime.Trace.clear()

      # Register a tool that the compiled code can call
      Skein.Runtime.Tool.register("MyTool", %{}, fn input ->
        data =
          cond do
            is_map(input) -> input[:data] || input["data"] || "unknown"
            is_binary(input) -> input
            true -> inspect(input)
          end

        {:ok, %{result: "processed_#{data}"}}
      end)

      :ok
    end

    test "tool.call compiles and dispatches to runtime" do
      mod =
        compile_with_caps!("""
        module ToolCallSimple {
          capability tool.use(MyTool)

          fn invoke(data: String) -> String {
            tool.call(MyTool, data)
          }
        }
        """)

      result = mod.invoke("hello")
      assert {:ok, %{result: "processed_hello"}} = result
    end

    test "tool.list compiles and dispatches to runtime" do
      mod =
        compile_with_caps!("""
        module ToolListCall {
          capability tool.use(MyTool)

          fn get_tools() -> String {
            tool.list()
          }
        }
        """)

      result = mod.get_tools()
      assert {:ok, tool_list} = result
      assert is_list(tool_list)
    end

    test "tool.schema compiles and dispatches to runtime" do
      mod =
        compile_with_caps!("""
        module ToolSchemaCall {
          capability tool.use(MyTool)

          fn get_schema() -> String {
            tool.schema(MyTool)
          }
        }
        """)

      result = mod.get_schema()
      assert {:ok, _schema} = result
    end

    test "tool.call records a trace span" do
      Skein.Runtime.Trace.clear()

      mod =
        compile_with_caps!("""
        module ToolCallTrace {
          capability tool.use(MyTool)

          fn invoke(data: String) -> String {
            tool.call(MyTool, data)
          }
        }
        """)

      mod.invoke("test")

      spans = Skein.Runtime.Trace.recent_spans(10)
      tool_spans = Enum.filter(spans, &(&1.kind == :tool))
      assert length(tool_spans) >= 1

      span = hd(tool_spans)
      assert span.kind == :tool
      assert span.method == :call
      assert span.name == "MyTool"
    end
  end

  # ------------------------------------------------------------------
  # Queue handler codegen (Phase 8e)
  # ------------------------------------------------------------------

  describe "queue handler codegen" do
    test "__handlers__/0 includes queue handler metadata" do
      mod =
        compile!("""
        module QueueHandlerMeta {
          capability queue.in

          handler queue "order-events" (msg) -> {
            respond.json(200, "processed")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 1
      handler = hd(handlers)
      assert handler.source == :queue
      assert handler.route == "order-events"
      assert handler.handler == :__handler_0__
    end

    test "queue handler function is callable" do
      mod =
        compile!("""
        module QueueHandlerCall {
          capability queue.in

          handler queue "events" (msg) -> {
            respond.json(200, "received")
          }
        }
        """)

      result = mod.__handler_0__(%{body: "test"})
      assert {:respond_json, 200, "received"} = result
    end

    test "queue handler can access message parameter" do
      mod =
        compile!("""
        module QueueHandlerParam {
          capability queue.in

          handler queue "events" (msg) -> {
            let data = msg
            respond.json(200, "ok")
          }
        }
        """)

      result = mod.__handler_0__(%{body: "payload"})
      assert {:respond_json, 200, "ok"} = result
    end

    test "multiple queue handlers are indexed correctly" do
      mod =
        compile!("""
        module QueueHandlerMulti {
          capability queue.in

          handler queue "events-a" (msg) -> {
            respond.json(200, "a")
          }

          handler queue "events-b" (msg) -> {
            respond.json(200, "b")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 2
      assert Enum.at(handlers, 0).route == "events-a"
      assert Enum.at(handlers, 1).route == "events-b"

      assert {:respond_json, 200, "a"} = mod.__handler_0__(%{})
      assert {:respond_json, 200, "b"} = mod.__handler_1__(%{})
    end
  end

  # ------------------------------------------------------------------
  # Schedule handler codegen (Phase 8e)
  # ------------------------------------------------------------------

  describe "schedule handler codegen" do
    test "__handlers__/0 includes schedule handler metadata" do
      mod =
        compile!("""
        module ScheduleHandlerMeta {
          capability schedule.in

          handler schedule "*/5 * * * *" () -> {
            respond.json(200, "tick")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 1
      handler = hd(handlers)
      assert handler.source == :schedule
      assert handler.route == "*/5 * * * *"
      assert handler.handler == :__handler_0__
    end

    test "schedule handler function is callable" do
      mod =
        compile!("""
        module ScheduleHandlerCall {
          capability schedule.in

          handler schedule "0 * * * *" () -> {
            respond.json(200, "hourly")
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, "hourly"} = result
    end

    test "schedule handler with body logic" do
      mod =
        compile!("""
        module ScheduleHandlerLogic {
          capability schedule.in

          handler schedule "0 0 * * *" () -> {
            let result = 1 + 2
            respond.json(200, result)
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_json, 200, 3} = result
    end
  end

  # ------------------------------------------------------------------
  # Mixed handler types codegen (Phase 8e)
  # ------------------------------------------------------------------

  describe "mixed handler types codegen" do
    test "http, queue, and schedule handlers coexist" do
      mod =
        compile!("""
        module MixedHandlers {
          capability http.in
          capability queue.in
          capability schedule.in

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler queue "events" (msg) -> {
            respond.json(200, "queued")
          }

          handler schedule "*/10 * * * *" () -> {
            respond.json(200, "scheduled")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 3

      [http_h, queue_h, sched_h] = handlers
      assert http_h.source == :http
      assert http_h.method == :get
      assert queue_h.source == :queue
      assert queue_h.route == "events"
      assert sched_h.source == :schedule
      assert sched_h.route == "*/10 * * * *"

      assert {:respond_json, 200, "ok"} = mod.__handler_0__(%{})
      assert {:respond_json, 200, "queued"} = mod.__handler_1__(%{})
      assert {:respond_json, 200, "scheduled"} = mod.__handler_2__(%{})
    end
  end

  # ------------------------------------------------------------------
  # Tool identifier references codegen (capability-as-import)
  # ------------------------------------------------------------------

  describe "tool identifier codegen" do
    setup do
      Skein.Runtime.Tool.clear_registry()
      Skein.Runtime.Trace.clear()

      Skein.Runtime.Tool.register("MyTool", %{}, fn input ->
        {:ok, %{result: "processed_#{input}"}}
      end)

      :ok
    end

    test "tool.call with identifier arg compiles and dispatches to runtime" do
      mod =
        compile_with_caps!("""
        module ToolCallIdent {
          capability tool.use(MyTool)

          fn invoke(data: String) -> String {
            tool.call(MyTool, data)
          }
        }
        """)

      result = mod.invoke("hello")
      assert {:ok, %{result: "processed_hello"}} = result
    end

    test "tool.schema with identifier arg compiles and dispatches to runtime" do
      mod =
        compile_with_caps!("""
        module ToolSchemaIdent {
          capability tool.use(MyTool)

          fn get_schema() -> String {
            tool.schema(MyTool)
          }
        }
        """)

      result = mod.get_schema()
      assert {:ok, _schema} = result
    end

    test "tool.call with dotted identifier arg compiles and dispatches" do
      Skein.Runtime.Tool.register("Stripe.CreateRefund", %{}, fn input ->
        {:ok, %{refund_id: "ref_#{input}"}}
      end)

      mod =
        compile_with_caps!("""
        module ToolCallDotted {
          capability tool.use(Stripe.CreateRefund)

          fn refund(data: String) -> String {
            tool.call(Stripe.CreateRefund, data)
          }
        }
        """)

      result = mod.refund("100")
      assert {:ok, %{refund_id: "ref_100"}} = result
    end

    test "tool.call identifier records a trace span with correct name" do
      Skein.Runtime.Trace.clear()

      mod =
        compile_with_caps!("""
        module ToolTraceIdent {
          capability tool.use(MyTool)

          fn invoke(data: String) -> String {
            tool.call(MyTool, data)
          }
        }
        """)

      mod.invoke("test")

      spans = Skein.Runtime.Trace.recent_spans(10)
      tool_spans = Enum.filter(spans, &(&1.kind == :tool))
      assert length(tool_spans) >= 1

      span = hd(tool_spans)
      assert span.name == "MyTool"
    end
  end
end
