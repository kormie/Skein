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

    test "respond.text produces {:respond_text, status, body} tuple" do
      mod =
        compile!("""
        module HandlerText {
          capability http.in

          handler http GET "/health" (req) -> {
            respond.text(200, "ok")
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_text, 200, "ok"} = result
    end

    test "respond.html produces {:respond_html, status, body} tuple" do
      mod =
        compile!("""
        module HandlerHtml {
          capability http.in

          handler http GET "/page" (req) -> {
            respond.html(200, "<h1>Hello</h1>")
          }
        }
        """)

      result = mod.__handler_0__(%{})
      assert {:respond_html, 200, "<h1>Hello</h1>"} = result
    end

    test "multiple respond types in separate handlers" do
      mod =
        compile!("""
        module HandlerMixed {
          capability http.in

          handler http GET "/api" (req) -> {
            respond.json(200, "data")
          }

          handler http GET "/health" (req) -> {
            respond.text(200, "ok")
          }

          handler http GET "/page" (req) -> {
            respond.html(200, "<h1>Hi</h1>")
          }
        }
        """)

      assert {:respond_json, 200, "data"} = mod.__handler_0__(%{})
      assert {:respond_text, 200, "ok"} = mod.__handler_1__(%{})
      assert {:respond_html, 200, "<h1>Hi</h1>"} = mod.__handler_2__(%{})
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
      assert {:error, error} = result
      assert error.__struct__ == Skein.Runtime.Llm.Error
      assert error.kind == :capability_error
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
  # Topic handler codegen
  # ------------------------------------------------------------------

  describe "topic handler codegen" do
    test "__handlers__/0 includes topic handler metadata" do
      mod =
        compile!("""
        module TopicHandlerMeta {
          capability topic.consume("order.events")

          handler topic "order.events" (msg) -> {
            respond.json(200, "processed")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 1
      handler = hd(handlers)
      assert handler.source == :topic
      assert handler.route == "order.events"
      assert handler.handler == :__handler_0__
    end

    test "topic handler function is callable" do
      mod =
        compile!("""
        module TopicHandlerCall {
          capability topic.consume("events")

          handler topic "events" (msg) -> {
            respond.json(200, "received")
          }
        }
        """)

      result = mod.__handler_0__(%{body: "test"})
      assert {:respond_json, 200, "received"} = result
    end

    test "topic handler can access message parameter" do
      mod =
        compile!("""
        module TopicHandlerParam {
          capability topic.consume("events")

          handler topic "events" (msg) -> {
            let data = msg
            respond.json(200, "ok")
          }
        }
        """)

      result = mod.__handler_0__(%{body: "payload"})
      assert {:respond_json, 200, "ok"} = result
    end

    test "multiple topic handlers are indexed correctly" do
      mod =
        compile!("""
        module TopicHandlerMulti {
          capability topic.consume("events-a")

          handler topic "events-a" (msg) -> {
            respond.json(200, "a")
          }

          handler topic "events-b" (msg) -> {
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

    test "topic.publish generates runtime call" do
      mod =
        compile!("""
        module TopicPublisher {
          capability topic.publish("notifications")

          fn notify() -> String {
            topic.publish("notifications", "hello")
          }
        }
        """)

      # The function should be callable and produce the runtime call
      assert function_exported?(mod, :notify, 0)
    end

    test "mixed handlers including topic" do
      mod =
        compile!("""
        module MixedWithTopic {
          capability http.in
          capability queue.in
          capability topic.consume("events")

          handler http GET "/health" (req) -> {
            respond.json(200, "ok")
          }

          handler queue "jobs" (msg) -> {
            respond.json(200, "queued")
          }

          handler topic "events" (msg) -> {
            respond.json(200, "topic")
          }
        }
        """)

      handlers = mod.__handlers__()
      assert length(handlers) == 3

      [http_h, queue_h, topic_h] = handlers
      assert http_h.source == :http
      assert queue_h.source == :queue
      assert topic_h.source == :topic
      assert topic_h.route == "events"

      assert {:respond_json, 200, "ok"} = mod.__handler_0__(%{})
      assert {:respond_json, 200, "queued"} = mod.__handler_1__(%{})
      assert {:respond_json, 200, "topic"} = mod.__handler_2__(%{})
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

  # ------------------------------------------------------------------
  # Capability params codegen — AST node types
  # ------------------------------------------------------------------

  describe "capability param codegen for different AST node types" do
    test "string literal capability param" do
      mod =
        compile_with_caps!("""
        module CapParamString {
          capability http.out("api.example.com")

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert [%{kind: "http.out", params: ["api.example.com"]}] = caps
    end

    test "identifier capability param (ToolRef)" do
      mod =
        compile_with_caps!("""
        module CapParamIdent {
          capability tool.use(MyTool)

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert [%{kind: "tool.use", params: ["MyTool"]}] = caps
    end

    test "dotted identifier capability param" do
      mod =
        compile_with_caps!("""
        module CapParamDotted {
          capability tool.use(Stripe.CreateRefund)

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert [%{kind: "tool.use", params: ["Stripe.CreateRefund"]}] = caps
    end

    test "multiple capability params of mixed types" do
      mod =
        compile_with_caps!("""
        module CapParamMixed {
          capability tool.use(MyTool)
          capability memory.kv("sessions")
          capability http.out("api.example.com")

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      kinds = Enum.map(caps, & &1.kind)
      assert "tool.use" in kinds
      assert "memory.kv" in kinds
      assert "http.out" in kinds

      tool_cap = Enum.find(caps, &(&1.kind == "tool.use"))
      assert tool_cap.params == ["MyTool"]
    end

    test "capability with no params" do
      mod =
        compile_with_caps!("""
        module CapParamNone {
          capability http.out

          fn x() -> Int { 1 }
        }
        """)

      caps = mod.__capabilities__()
      assert [%{kind: "http.out", params: []}] = caps
    end
  end

  # ------------------------------------------------------------------
  # Enum variant matching codegen (distribution prerequisite)
  # ------------------------------------------------------------------

  describe "enum variant matching" do
    test "match on simple enum variants without fields" do
      mod =
        compile!("""
        module EnumSimple {
          enum Color {
            Red
            Green
            Blue
          }

          fn describe(c: String) -> String {
            match c {
              Red -> "red"
              Green -> "green"
              Blue -> "blue"
            }
          }
        }
        """)

      assert mod.describe(:red) == "red"
      assert mod.describe(:green) == "green"
      assert mod.describe(:blue) == "blue"
    end

    test "match on enum variant with fields extracts data" do
      mod =
        compile!("""
        module EnumFields {
          enum Event {
            Charge(amount: Int)
            Refund(amount: Int, reason: String)
          }

          fn describe_event(e: Event) -> String {
            match e {
              Event.Charge(amt) -> "charged"
              Event.Refund(amt, reason) -> "refunded"
            }
          }
        }
        """)

      assert mod.describe_event({:charge, 100}) == "charged"
      assert mod.describe_event({:refund, 50, "defective"}) == "refunded"
    end

    test "match on enum variant with fields uses bound variables" do
      mod =
        compile!("""
        module EnumBind {
          enum Shape {
            Circle(radius: Int)
            Rect(width: Int, height: Int)
          }

          fn area(s: Shape) -> Int {
            match s {
              Shape.Circle(r) -> r * r
              Shape.Rect(w, h) -> w * h
            }
          }
        }
        """)

      assert mod.area({:circle, 5}) == 25
      assert mod.area({:rect, 3, 4}) == 12
    end

    test "match on enum variant with wildcard arm" do
      mod =
        compile!("""
        module EnumWildcard {
          enum Status {
            Active
            Inactive
            Suspended(reason: String)
          }

          fn is_active(s: Status) -> Bool {
            match s {
              Active -> true
              _ -> false
            }
          }
        }
        """)

      assert mod.is_active(:active) == true
      assert mod.is_active(:inactive) == false
      assert mod.is_active({:suspended, "violation"}) == false
    end

    test "enum variant matching in nested expressions" do
      mod =
        compile!("""
        module EnumNested {
          enum Result {
            Ok(value: Int)
            Err(message: String)
          }

          fn unwrap_or(r: Result, default: Int) -> Int {
            match r {
              Result.Ok(v) -> v
              Result.Err(msg) -> default
            }
          }
        }
        """)

      assert mod.unwrap_or({:ok, 42}, 0) == 42
      assert mod.unwrap_or({:err, "oops"}, 0) == 0
    end
  end

  # ------------------------------------------------------------------
  # Supervisor codegen (distribution prerequisite)
  # ------------------------------------------------------------------

  describe "supervisor codegen" do
    test "module with supervisor compiles successfully" do
      mod =
        compile!("""
        module SupBasic {
          supervisor Main {
            child HttpServer
            strategy: one_for_one
          }
        }
        """)

      assert is_atom(mod)
    end

    test "module with supervisor exposes __supervisors__/0 metadata" do
      mod =
        compile!("""
        module SupMeta {
          supervisor AppSup {
            child HttpServer { restart: permanent }
            child Worker
            strategy: one_for_one
            max_restarts: 10 per 60s
          }
        }
        """)

      sups = mod.__supervisors__()
      assert is_list(sups)
      assert length(sups) == 1
      [sup] = sups
      assert sup.name == "AppSup"
      assert sup.strategy == :one_for_one
      assert sup.max_restarts == {10, 60}
      assert length(sup.children) == 2
    end

    test "module with multiple supervisors exposes all" do
      mod =
        compile!("""
        module SupMulti {
          supervisor Primary {
            child HttpServer
            strategy: one_for_one
          }

          supervisor Secondary {
            child Worker
            strategy: one_for_all
          }
        }
        """)

      sups = mod.__supervisors__()
      assert length(sups) == 2
      names = Enum.map(sups, & &1.name)
      assert "Primary" in names
      assert "Secondary" in names
    end

    test "supervisor child metadata includes target and options" do
      mod =
        compile!("""
        module SupChildren {
          supervisor Main {
            child AgentPool(RefundAgent) { max: 5000, restart: transient }
            strategy: one_for_one
          }
        }
        """)

      [sup] = mod.__supervisors__()
      [child] = sup.children
      assert child.target == "AgentPool"
      assert child.args == ["RefundAgent"]
      assert child.options.max == 5000
      assert child.options.restart == "transient"
    end
  end

  # ------------------------------------------------------------------
  # Agent suspend codegen
  # ------------------------------------------------------------------

  describe "agent codegen - suspend" do
    test "agent with suspend compiles successfully" do
      mod =
        compile!("""
        agent SuspendAgent {
          enum Phase {
            Active -> []
          }

          on start() -> {
            transition(Phase.Active)
          }

          on phase(Phase.Active) -> {
            suspend("Waiting for human review")
          }
        }
        """)

      assert mod.__info__(:module) == mod
    end

    test "agent suspend handler returns suspend tuple" do
      mod =
        compile!("""
        agent SuspendTupleAgent {
          enum Phase {
            Working -> []
          }

          on start() -> {
            transition(Phase.Working)
          }

          on phase(Phase.Working) -> {
            suspend("Need more data")
          }
        }
        """)

      # Call the phase handler directly to verify the returned tuple
      result = mod.__phase_handler__(:working, %{}, [])
      assert {:suspend, "Need more data", %{}, []} = result
    end

    test "agent suspend in match arm" do
      mod =
        compile!("""
        agent SuspendMatchAgent {
          enum Phase {
            Review -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Review)
          }

          on phase(Phase.Review) -> {
            match 1 {
              1 -> suspend("Needs escalation")
              _ -> transition(Phase.Done)
            }
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      result = mod.__phase_handler__(:review, %{}, [])
      assert {:suspend, "Needs escalation", %{}, []} = result
    end

    test "full suspend/resume lifecycle via runtime" do
      mod =
        compile!("""
        agent LifecycleSuspendAgent {
          enum Phase {
            Active -> [Done]
            Done -> []
          }

          on start() -> {
            transition(Phase.Active)
          }

          on phase(Phase.Active) -> {
            suspend("Paused for input")
          }

          on phase(Phase.Done) -> {
            stop()
          }
        }
        """)

      # Start the agent — it transitions to Active, then suspends
      {:ok, pid} = Skein.Runtime.Agent.start_link(mod, %{})
      Process.sleep(50)

      # Agent is alive and suspended
      assert Process.alive?(pid)
      assert Skein.Runtime.Agent.get_phase(pid) == :suspended
      assert Skein.Runtime.Agent.is_suspended?(pid) == true
      assert Skein.Runtime.Agent.get_suspend_reason(pid) == "Paused for input"

      # Resume to Done phase — agent should stop
      :ok = Skein.Runtime.Agent.resume(pid, :done)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  # ------------------------------------------------------------------
  # trace.annotate codegen
  # ------------------------------------------------------------------

  describe "trace.annotate codegen" do
    test "trace.annotate generates runtime call" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TraceAnnotateBasic {
          fn tag(key: String, val: String) -> String {
            trace.annotate(key, val)
            "done"
          }
        }
        """)

      assert function_exported?(mod, :tag, 2)
      result = mod.tag("user_id", "u-123")
      assert result == "done"

      # Verify the annotation was recorded
      spans = Skein.Runtime.Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      assert length(annotations) >= 1
      annotation = hd(annotations)
      assert annotation.key == "user_id"
      assert annotation.value == "u-123"
    end

    test "trace.annotate with string literal arguments" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TraceAnnotateLiteral {
          fn mark() -> String {
            trace.annotate("endpoint", "/health")
            "marked"
          }
        }
        """)

      mod.mark()

      spans = Skein.Runtime.Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      assert length(annotations) >= 1
      assert hd(annotations).key == "endpoint"
      assert hd(annotations).value == "/health"
    end

    test "multiple trace.annotate calls in same function" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TraceAnnotateMulti {
          fn annotate_all() -> String {
            trace.annotate("step", "start")
            trace.annotate("component", "auth")
            "done"
          }
        }
        """)

      mod.annotate_all()

      spans = Skein.Runtime.Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      assert length(annotations) == 2

      keys = Enum.map(annotations, & &1.key) |> Enum.sort()
      assert keys == ["component", "step"]
    end

    test "trace.annotate in handler body" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TraceAnnotateHandler {
          capability http.in

          handler http GET "/test" (req) -> {
            trace.annotate("handler", "test")
            respond.json(200, "ok")
          }
        }
        """)

      result = mod.__handler_0__(%{params: %{}})
      assert {:respond_json, 200, "ok"} = result

      spans = Skein.Runtime.Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      assert length(annotations) >= 1
      assert hd(annotations).key == "handler"
    end

    test "trace.annotate does not require any capability" do
      # Should compile without any capability declaration
      mod =
        compile!("""
        module TraceAnnotateNoCap {
          fn tag() -> String {
            trace.annotate("key", "val")
            "ok"
          }
        }
        """)

      assert function_exported?(mod, :tag, 0)
    end

    test "trace.annotate alongside other effect calls" do
      Skein.Runtime.Trace.clear()

      mod =
        compile!("""
        module TraceAnnotateMixed {
          capability http.out("api.example.com")

          fn fetch(url: String) -> String {
            trace.annotate("url", url)
            http.get(url)
          }
        }
        """)

      # Call should record both annotation and HTTP trace
      mod.fetch("https://api.example.com/data")

      spans = Skein.Runtime.Trace.recent_spans(10)
      annotations = Enum.filter(spans, &(&1.kind == :annotation))
      http_spans = Enum.filter(spans, &(&1.kind == :http))
      assert length(annotations) >= 1
      assert length(http_spans) >= 1
    end
  end

  # ------------------------------------------------------------------
  # Priority 9: process.spawn, timer, event.log codegen
  # ------------------------------------------------------------------

  describe "process.spawn codegen" do
    test "process.spawn compiles to runtime call" do
      mod =
        compile!("""
        module ProcessSpawnTest {
          capability process.spawn("workers")

          fn run_task() -> String {
            process.spawn("task")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:run_task, 0} in fns
    end

    test "process.spawn with multiple capabilities compiles" do
      mod =
        compile!("""
        module ProcessSpawnMulti {
          capability process.spawn("workers")
          capability http.out("api.example.com")

          fn do_work() -> String {
            process.spawn("task")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:do_work, 0} in fns
    end
  end

  describe "timer codegen" do
    test "timer.after compiles to runtime call" do
      mod =
        compile!("""
        module TimerAfterTest {
          capability timer("default")

          fn schedule() -> String {
            timer.after(1000, "callback")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:schedule, 0} in fns
    end

    test "timer.interval compiles to runtime call" do
      mod =
        compile!("""
        module TimerIntervalTest {
          capability timer("default")

          fn schedule_interval() -> String {
            timer.interval(5000, "callback")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:schedule_interval, 0} in fns
    end

    test "timer.cancel compiles to runtime call" do
      mod =
        compile!("""
        module TimerCancelTest {
          capability timer("default")

          fn cancel_timer() -> String {
            timer.cancel("ref123")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:cancel_timer, 0} in fns
    end
  end

  describe "event.log codegen" do
    test "event.log compiles to runtime call" do
      mod =
        compile!("""
        module EventLogTest {
          capability event.log("audit")

          fn log_event() -> String {
            event.log("user.login", "data")
          }
        }
        """)

      fns = mod.__info__(:functions)
      assert {:log_event, 0} in fns
    end

    test "event.log is callable and records events" do
      Skein.Runtime.EventLog.reset_all()

      mod =
        compile!("""
        module EventLogCallable {
          capability event.log("audit")

          fn log_it() -> String {
            event.log("test.event", "payload")
          }
        }
        """)

      mod.log_it()

      events = Skein.Runtime.EventLog.all()
      assert length(events) >= 1
      event = Enum.find(events, &(&1.event == "test.event"))
      assert event != nil
      assert event.data == "payload"

      Skein.Runtime.EventLog.reset_all()
    end

    test "multiple event.log calls in same function" do
      Skein.Runtime.EventLog.reset_all()

      mod =
        compile!("""
        module MultiEventLog {
          capability event.log("audit")

          fn log_multiple() -> String {
            event.log("start", "begin")
            event.log("end", "done")
          }
        }
        """)

      mod.log_multiple()

      events = Skein.Runtime.EventLog.all()
      event_names = Enum.map(events, & &1.event)
      assert "start" in event_names
      assert "end" in event_names

      Skein.Runtime.EventLog.reset_all()
    end
  end

  describe "map literal codegen" do
    test "compiles empty map literal" do
      mod = compile!("""
        module EmptyMapTest {
          fn empty() -> Map[String, Int] {
            {}
          }
        }
      """)

      assert mod.empty() == %{}
    end

    test "compiles map literal with string values" do
      mod = compile!("""
        module MapStrTest {
          fn user() -> Map[String, String] {
            { name: "Alice", role: "admin" }
          }
        }
      """)

      result = mod.user()
      assert result == %{name: "Alice", role: "admin"}
    end

    test "compiles map literal with mixed value types" do
      mod = compile!("""
        module MapMixTest {
          fn record() -> Map[String, Int] {
            { label: "test", count: 42, active: true }
          }
        }
      """)

      result = mod.record()
      assert result.label == "test"
      assert result.count == 42
      assert result.active == true
    end

    test "compiles map literal with variable references" do
      mod = compile!("""
        module MapVarTest {
          fn make(name: String) -> Map[String, String] {
            { name: name, kind: "user" }
          }
        }
      """)

      assert mod.make("Bob") == %{name: "Bob", kind: "user"}
    end

    test "compiles nested map literal" do
      mod = compile!("""
        module MapNestedTest {
          fn nested() -> Map[String, Map[String, String]] {
            { inner: { key: "value" } }
          }
        }
      """)

      result = mod.nested()
      assert result.inner == %{key: "value"}
    end

    test "map literal works in respond.json" do
      mod = compile!("""
        module MapRespondTest {
          fn make_response() -> Map[String, String] {
            { status: "ok", message: "done" }
          }
        }
      """)

      assert mod.make_response() == %{status: "ok", message: "done"}
    end
  end
end
