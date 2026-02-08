defmodule Skein.ParserTest do
  use ExUnit.Case, async: true

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.AST

  # Helper: lex then parse
  defp parse(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Parser.parse(tokens)
  end

  describe "parse/1 - empty module" do
    test "parses an empty module" do
      assert {:ok, %AST.Module{name: "Hello", declarations: []}} =
               parse("module Hello { }")
    end

    test "preserves source location" do
      {:ok, mod} = parse("module Hello { }")
      assert mod.meta.line == 1
      assert mod.meta.col == 1
    end
  end

  describe "parse/1 - function declarations" do
    test "parses a function with no params" do
      source = """
      module M {
        fn greet() -> String {
          "hello"
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Fn{name: "greet", params: []} = fn_decl
      assert %AST.TypeRef{name: "String"} = fn_decl.return_type
    end

    test "parses a function with params" do
      source = """
      module M {
        fn add(a: Int, b: Int) -> Int {
          a + b
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Fn{name: "add"} = fn_decl
      assert [%AST.Field{name: "a"}, %AST.Field{name: "b"}] = fn_decl.params
      assert %AST.TypeRef{name: "Int"} = fn_decl.return_type
    end

    test "parses function body as a block" do
      source = """
      module M {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.StringLit{}]} = fn_decl.body
    end

    test "parses multiple functions" do
      source = """
      module M {
        fn a() -> Int { 1 }
        fn b() -> Int { 2 }
        fn c() -> Int { 3 }
      }
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      assert length(decls) == 3
      assert Enum.all?(decls, &match?(%AST.Fn{}, &1))
    end
  end

  describe "parse/1 - let bindings" do
    test "parses a simple let binding" do
      source = """
      module M {
        fn f() -> Int {
          let x = 42
          x
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [let, ident]} = fn_decl.body
      assert %AST.Let{name: "x", value: %AST.IntLit{value: 42}} = let
      assert %AST.Identifier{name: "x"} = ident
    end

    test "parses let with expression value" do
      source = """
      module M {
        fn f(a: Int, b: Int) -> Int {
          let sum = a + b
          sum
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [let, _]} = fn_decl.body
      assert %AST.Let{name: "sum", value: %AST.BinaryOp{op: :+}} = let
    end
  end

  describe "parse/1 - match expressions" do
    test "parses a simple match" do
      source = """
      module M {
        fn f(n: Int) -> String {
          match n > 0 {
            true  -> "positive"
            false -> "non-positive"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [match]} = fn_decl.body
      assert %AST.Match{} = match
      assert %AST.BinaryOp{op: :>} = match.subject
      assert [arm1, arm2] = match.arms
      assert %AST.MatchArm{pattern: %AST.BoolLit{value: true}} = arm1
      assert %AST.MatchArm{pattern: %AST.BoolLit{value: false}} = arm2
    end

    test "match arms can have block bodies" do
      source = """
      module M {
        fn f(x: Bool) -> Int {
          match x {
            true -> {
              let a = 1
              a
            }
            false -> 0
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [match]} = fn_decl.body
      [arm1, _arm2] = match.arms
      assert %AST.Block{expressions: [%AST.Let{}, %AST.Identifier{}]} = arm1.body
    end
  end

  describe "parse/1 - binary operators" do
    test "parses arithmetic" do
      source = "module M { fn f() -> Int { 1 + 2 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.BinaryOp{op: :+, left: %AST.IntLit{value: 1}, right: %AST.IntLit{value: 2}}
               ]
             } =
               fn_decl.body
    end

    test "respects multiplication precedence over addition" do
      source = "module M { fn f() -> Int { 1 + 2 * 3 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [expr]} = fn_decl.body
      # Should parse as 1 + (2 * 3)
      assert %AST.BinaryOp{
               op: :+,
               left: %AST.IntLit{value: 1},
               right: %AST.BinaryOp{
                 op: :*,
                 left: %AST.IntLit{value: 2},
                 right: %AST.IntLit{value: 3}
               }
             } = expr
    end

    test "left-associative addition" do
      source = "module M { fn f() -> Int { 1 + 2 + 3 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [expr]} = fn_decl.body
      # Should parse as (1 + 2) + 3
      assert %AST.BinaryOp{
               op: :+,
               left: %AST.BinaryOp{
                 op: :+,
                 left: %AST.IntLit{value: 1},
                 right: %AST.IntLit{value: 2}
               },
               right: %AST.IntLit{value: 3}
             } = expr
    end

    test "parses comparison operators" do
      source = "module M { fn f(n: Int) -> Bool { n > 0 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.BinaryOp{op: :>}]} = fn_decl.body
    end

    test "parses equality operators" do
      source = "module M { fn f(a: Int, b: Int) -> Bool { a == b } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.BinaryOp{op: :==}]} = fn_decl.body
    end

    test "parses logical operators" do
      source = "module M { fn f(a: Bool, b: Bool) -> Bool { a && b || true } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [expr]} = fn_decl.body
      # || has lower precedence than &&, so: (a && b) || true
      assert %AST.BinaryOp{op: :||, left: %AST.BinaryOp{op: :&&}} = expr
    end
  end

  describe "parse/1 - pipe expressions" do
    test "parses a simple pipe" do
      source = """
      module M {
        fn f(s: String) -> String {
          s |> String.trim()
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Pipe{left: %AST.Identifier{name: "s"}}]} = fn_decl.body
    end

    test "parses chained pipes" do
      source = """
      module M {
        fn f(s: String) -> String {
          s |> String.trim() |> String.upcase()
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [pipe]} = fn_decl.body
      # Left-associative: (s |> trim) |> upcase
      assert %AST.Pipe{left: %AST.Pipe{}} = pipe
    end
  end

  describe "parse/1 - function calls" do
    test "parses a zero-arg call" do
      source = "module M { fn f() -> Int { foo() } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Call{target: %AST.Identifier{name: "foo"}, args: []}]} =
               fn_decl.body
    end

    test "parses a call with args" do
      source = "module M { fn f() -> Int { add(1, 2) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body
      assert %AST.Call{args: [%AST.IntLit{value: 1}, %AST.IntLit{value: 2}]} = call
    end

    test "parses method-style calls" do
      source = "module M { fn f() -> String { String.trim(s) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body
      assert %AST.Call{target: %AST.FieldAccess{}} = call
    end
  end

  describe "parse/1 - field access" do
    test "parses simple field access" do
      source = "module M { fn f() -> Int { x.y } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [%AST.FieldAccess{subject: %AST.Identifier{name: "x"}, field: "y"}]
             } =
               fn_decl.body
    end

    test "parses chained field access" do
      source = "module M { fn f() -> Int { a.b.c } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.FieldAccess{subject: %AST.FieldAccess{}, field: "c"}]} =
               fn_decl.body
    end
  end

  describe "parse/1 - string literals" do
    test "parses a simple string" do
      source = "module M { fn f() -> String { \"hello\" } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.StringLit{segments: [{:literal, "hello"}]}]} =
               fn_decl.body
    end

    test "parses a string with interpolation" do
      source = "module M { fn f(name: String) -> String { \"Hello, \${name}!\" } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.StringLit{segments: segments}]} = fn_decl.body
      assert [{:literal, "Hello, "}, {:interpolation, _}, {:literal, "!"}] = segments
    end
  end

  describe "parse/1 - literals" do
    test "parses boolean true" do
      source = "module M { fn f() -> Bool { true } }"
      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.BoolLit{value: true}]} = fn_decl.body
    end

    test "parses boolean false" do
      source = "module M { fn f() -> Bool { false } }"
      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.BoolLit{value: false}]} = fn_decl.body
    end

    test "parses integer" do
      source = "module M { fn f() -> Int { 42 } }"
      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.IntLit{value: 42}]} = fn_decl.body
    end

    test "parses float" do
      source = "module M { fn f() -> Float { 3.14 } }"
      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.FloatLit{value: 3.14}]} = fn_decl.body
    end
  end

  describe "parse/1 - unary operators" do
    test "parses prefix not" do
      source = "module M { fn f(b: Bool) -> Bool { !b } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [%AST.UnaryOp{op: :not, operand: %AST.Identifier{name: "b"}}]
             } =
               fn_decl.body
    end

    test "parses postfix unwrap (!)" do
      source = "module M { fn f() -> Int { get_value()! } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.UnaryOp{op: :unwrap}]} = fn_decl.body
    end

    test "parses postfix propagate (?)" do
      source = "module M { fn f() -> Int { get_value()? } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.UnaryOp{op: :propagate}]} = fn_decl.body
    end
  end

  describe "parse/1 - type declarations" do
    test "parses a simple type" do
      source = """
      module M {
        type User {
          name: String
          age: Int
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [type_decl]}} = parse(source)
      assert %AST.TypeDecl{name: "User"} = type_decl
      assert [%AST.Field{name: "name"}, %AST.Field{name: "age"}] = type_decl.fields
    end

    test "parses parameterized types in fields" do
      source = """
      module M {
        type Container {
          items: List[String]
          result: Result[Int, String]
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [type_decl]}} = parse(source)
      [items, result] = type_decl.fields
      assert %AST.TypeRef{name: "List", params: [%AST.TypeRef{name: "String"}]} = items.type

      assert %AST.TypeRef{
               name: "Result",
               params: [%AST.TypeRef{name: "Int"}, %AST.TypeRef{name: "String"}]
             } =
               result.type
    end

    test "parses type with annotations" do
      source = """
      module M {
        type Money {
          amount: Int @min(0)
          currency: String
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [type_decl]}} = parse(source)
      [amount, _currency] = type_decl.fields
      assert [%AST.Annotation{name: "min", value: %AST.IntLit{value: 0}}] = amount.annotations
    end
  end

  describe "parse/1 - enum declarations" do
    test "parses a simple enum" do
      source = """
      module M {
        enum Status {
          Active
          Inactive
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [enum_decl]}} = parse(source)
      assert %AST.EnumDecl{name: "Status"} = enum_decl
      assert [%AST.Variant{name: "Active"}, %AST.Variant{name: "Inactive"}] = enum_decl.variants
    end

    test "parses enum with variant data" do
      source = """
      module M {
        enum Status {
          Active
          Suspended(reason: String)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [enum_decl]}} = parse(source)
      [_active, suspended] = enum_decl.variants
      assert [%AST.Field{name: "reason"}] = suspended.fields
    end

    test "parses enum with transitions" do
      source = """
      module M {
        enum Phase {
          Analyze -> [Refund, Done]
          Refund -> [Done]
          Done -> []
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [enum_decl]}} = parse(source)
      [analyze, refund, done] = enum_decl.variants
      assert analyze.transitions == ["Refund", "Done"]
      assert refund.transitions == ["Done"]
      assert done.transitions == []
    end
  end

  describe "parse/1 - capability declarations" do
    test "parses a capability with params" do
      source = "module M { capability http.out(\"api.example.com\") }"

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "http.out"} = cap
      assert [%AST.StringLit{segments: [{:literal, "api.example.com"}]}] = cap.params
    end

    test "parses capability without params" do
      source = "module M { capability http.in }"

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "http.in", params: []} = cap
    end
  end

  describe "parse/1 - parenthesized expressions" do
    test "parses parenthesized expression" do
      source = "module M { fn f() -> Int { (1 + 2) * 3 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [expr]} = fn_decl.body
      # (1 + 2) * 3
      assert %AST.BinaryOp{
               op: :*,
               left: %AST.BinaryOp{op: :+},
               right: %AST.IntLit{value: 3}
             } = expr
    end
  end

  describe "parse/1 - fn ref" do
    test "parses fn reference" do
      source = "module M { fn f() -> Int { &my_fn } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.FnRef{name: "my_fn"}]} = fn_decl.body
    end
  end

  describe "parse/1 - the hello.skein Phase 1 acceptance example" do
    test "parses the complete hello.skein example" do
      source = """
      module Hello {
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
      """

      assert {:ok, %AST.Module{name: "Hello", declarations: decls}} = parse(source)
      assert length(decls) == 3

      [greet, add, classify] = decls

      # greet function
      assert %AST.Fn{name: "greet"} = greet
      assert [%AST.Field{name: "name", type: %AST.TypeRef{name: "String"}}] = greet.params
      assert %AST.TypeRef{name: "String"} = greet.return_type
      assert %AST.Block{expressions: [%AST.StringLit{segments: segments}]} = greet.body
      assert [{:literal, "Hello, "}, {:interpolation, _}, {:literal, "!"}] = segments

      # add function
      assert %AST.Fn{name: "add"} = add
      assert length(add.params) == 2
      assert %AST.Block{expressions: [%AST.BinaryOp{op: :+}]} = add.body

      # classify function
      assert %AST.Fn{name: "classify"} = classify
      assert %AST.Block{expressions: [%AST.Match{} = match]} = classify.body
      assert %AST.BinaryOp{op: :>} = match.subject
      assert length(match.arms) == 2
    end
  end

  describe "parse/1 - handler declarations" do
    test "parses a simple GET handler" do
      source = """
      module M {
        capability http.in
        handler http GET "/users" (req) -> {
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert %AST.Handler{source: "http", method: "get", route: "/users", param: "req"} = handler
      assert %AST.Block{} = handler.body
    end

    test "parses a POST handler" do
      source = """
      module M {
        capability http.in
        handler http POST "/users" (req) -> {
          respond.json(201, "created")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert %AST.Handler{method: "post", route: "/users"} = handler
    end

    test "parses a handler with route params" do
      source = """
      module M {
        capability http.in
        handler http GET "/users/:id" (req) -> {
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.route == "/users/:id"
    end

    test "parses all HTTP methods" do
      for method <- ~w(GET POST PUT PATCH DELETE) do
        source = """
        module M#{method} {
          capability http.in
          handler http #{method} "/test" (req) -> {
            respond.json(200, "ok")
          }
        }
        """

        assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
        assert handler.method == String.downcase(method)
      end
    end

    test "parses multiple handlers" do
      source = """
      module M {
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
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      handlers = Enum.filter(decls, &match?(%AST.Handler{}, &1))
      assert length(handlers) == 3
    end

    test "parses handler with complex body" do
      source = """
      module M {
        capability http.in

        handler http GET "/users/:id" (req) -> {
          let id = req.params.id
          match id == "admin" {
            true  -> respond.json(200, "admin user")
            false -> respond.json(200, "regular user")
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Let{}, %AST.Match{}]} = handler.body
    end

    test "parses handler mixed with functions" do
      source = """
      module M {
        capability http.in

        fn helper() -> String { "ok" }

        handler http GET "/test" (req) -> {
          respond.json(200, helper())
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl, handler]}} = parse(source)
      assert %AST.Fn{name: "helper"} = fn_decl
      assert %AST.Handler{method: "get"} = handler
    end

    test "preserves handler source location" do
      source = """
      module M {
        capability http.in
        handler http GET "/test" (req) -> { respond.json(200, "ok") }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.meta.line == 3
    end

    test "returns error for missing HTTP method" do
      source = """
      module M {
        handler http "/test" (req) -> { respond.json(200, "ok") }
      }
      """

      assert {:error, [%Skein.Error{code: "E0001"}]} = parse(source)
    end

    test "returns error for invalid HTTP method" do
      source = """
      module M {
        handler http CONNECT "/test" (req) -> { respond.json(200, "ok") }
      }
      """

      assert {:error, [%Skein.Error{code: "E0001"}]} = parse(source)
    end
  end

  describe "parse/1 - error cases" do
    test "returns error for missing module keyword" do
      assert {:error, [%Skein.Error{code: "E0001"}]} = parse("Hello { }")
    end

    test "returns error for missing module name" do
      assert {:error, [%Skein.Error{code: "E0001"}]} = parse("module { }")
    end

    test "returns error for missing opening brace" do
      assert {:error, [%Skein.Error{code: "E0001"}]} = parse("module Hello }")
    end

    test "returns error for unexpected token in declaration" do
      assert {:error, [%Skein.Error{code: "E0001"}]} = parse("module Hello { 42 }")
    end
  end

  # ------------------------------------------------------------------
  # Agent declarations (Phase 6a)
  # ------------------------------------------------------------------

  describe "parse/1 - agent declarations" do
    test "parses an empty agent" do
      source = "agent MyAgent { }"

      assert {:ok,
              %AST.Agent{
                name: "MyAgent",
                capabilities: [],
                state: [],
                phases: nil,
                handlers: [],
                fns: []
              }} =
               parse(source)
    end

    test "parses agent with state" do
      source = """
      agent MyAgent {
        state {
          ticket_id: Uuid
          customer_id: String
        }
      }
      """

      assert {:ok, %AST.Agent{state: state}} = parse(source)
      assert length(state) == 2
      assert %AST.Field{name: "ticket_id", type: %AST.TypeRef{name: "Uuid"}} = hd(state)
    end

    test "parses agent with phase enum" do
      source = """
      agent MyAgent {
        enum Phase {
          Analyze -> [Refund, Done]
          Refund -> [Done, Failed]
          Failed -> [Analyze]
          Done -> []
        }
      }
      """

      assert {:ok, %AST.Agent{phases: phases}} = parse(source)
      assert %AST.EnumDecl{name: "Phase", variants: variants} = phases
      assert length(variants) == 4

      analyze = hd(variants)
      assert %AST.Variant{name: "Analyze", transitions: ["Refund", "Done"]} = analyze

      done = List.last(variants)
      assert %AST.Variant{name: "Done", transitions: []} = done
    end

    test "parses agent with on start handler" do
      source = """
      agent MyAgent {
        on start(ticket_id: Uuid) -> {
          transition(Phase.Analyze)
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.AgentHandler{kind: :start, params: [param]} = handler
      assert %AST.Field{name: "ticket_id", type: %AST.TypeRef{name: "Uuid"}} = param
    end

    test "parses agent with on phase handler" do
      source = """
      agent MyAgent {
        on phase(Phase.Analyze) -> {
          transition(Phase.Done)
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.AgentHandler{kind: :phase, phase: "Analyze"} = handler
    end

    test "parses agent with capabilities" do
      source = """
      agent MyAgent {
        capability model("anthropic", "claude-sonnet-4-5")
      }
      """

      assert {:ok, %AST.Agent{capabilities: [cap]}} = parse(source)
      assert %AST.Capability{kind: "model"} = cap
    end

    test "parses agent with functions" do
      source = """
      agent MyAgent {
        fn helper(x: Int) -> Int {
          x + 1
        }
      }
      """

      assert {:ok, %AST.Agent{fns: [fn_decl]}} = parse(source)
      assert %AST.Fn{name: "helper"} = fn_decl
    end

    test "parses complete agent with all parts" do
      source = """
      agent RefundAgent {
        capability model("anthropic", "claude-sonnet-4-5")

        state {
          ticket_id: Uuid
          customer_id: String
        }

        enum Phase {
          Analyze -> [Refund, Done]
          Refund -> [Done, Failed]
          Failed -> [Analyze]
          Done -> []
        }

        on start(ticket_id: Uuid, customer_id: String) -> {
          transition(Phase.Analyze)
        }

        on phase(Phase.Analyze) -> {
          transition(Phase.Refund)
        }

        on phase(Phase.Refund) -> {
          transition(Phase.Done)
        }

        on phase(Phase.Failed) -> {
          stop()
        }

        on phase(Phase.Done) -> {
          stop()
        }
      }
      """

      assert {:ok, %AST.Agent{} = agent} = parse(source)
      assert agent.name == "RefundAgent"
      assert length(agent.capabilities) == 1
      assert length(agent.state) == 2
      assert %AST.EnumDecl{name: "Phase"} = agent.phases
      assert length(agent.handlers) == 5
    end
  end

  describe "parse/1 - transition and stop expressions" do
    test "parses transition expression" do
      source = """
      agent A {
        on start() -> {
          transition(Phase.Init)
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Transition{phase: "Init"}]} = handler.body
    end

    test "parses stop expression" do
      source = """
      agent A {
        on phase(Phase.Done) -> {
          stop()
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Stop{}]} = handler.body
    end

    test "parses emit expression with fields" do
      source = """
      agent A {
        on phase(Phase.Done) -> {
          emit RefundIssued { ticket_id: 42, amount: 100 }
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Emit{event_name: "RefundIssued", fields: fields}]} =
               handler.body

      assert length(fields) == 2
      assert {"ticket_id", %AST.IntLit{value: 42}} = hd(fields)
    end

    test "parses emit expression without fields" do
      source = """
      agent A {
        on phase(Phase.Done) -> {
          emit Completed
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Emit{event_name: "Completed", fields: []}]} =
               handler.body
    end
  end

  describe "parse/1 - agent with match and transition" do
    test "parses transition inside match arms" do
      source = """
      agent A {
        enum Phase {
          Init -> [Done, Failed]
          Done -> []
          Failed -> []
        }

        on phase(Phase.Init) -> {
          match true {
            true -> transition(Phase.Done)
            false -> transition(Phase.Failed)
          }
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Match{arms: [arm1, arm2]}]} = handler.body
      assert %AST.Transition{phase: "Done"} = arm1.body
      assert %AST.Transition{phase: "Failed"} = arm2.body
    end
  end

  # ------------------------------------------------------------------
  # Tool declarations (Phase 6c)
  # ------------------------------------------------------------------

  describe "parse/1 - tool declarations" do
    test "parses a minimal tool declaration" do
      source = """
      module M {
        tool CreateRefund {
          input {
            amount: Int
          }

          output {
            id: String
          }

          implement {
            "refund_123"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert %AST.ToolDecl{name: "CreateRefund"} = tool
      assert [%AST.Field{name: "amount", type: %AST.TypeRef{name: "Int"}}] = tool.input
      assert [%AST.Field{name: "id", type: %AST.TypeRef{name: "String"}}] = tool.output
      assert %AST.Block{} = tool.implement
    end

    test "parses tool with dotted name" do
      source = """
      module M {
        tool Stripe.CreateRefund {
          input {
            customer_id: String
          }

          output {
            id: String
          }

          implement {
            "ok"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert %AST.ToolDecl{name: "Stripe.CreateRefund"} = tool
    end

    test "parses tool with description" do
      source = """
      module M {
        tool MyTool {
          description: "A helpful tool"

          input {
            name: String
          }

          output {
            result: String
          }

          implement {
            "done"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert %AST.ToolDecl{description: "A helpful tool"} = tool
    end

    test "parses tool with errors block" do
      source = """
      module M {
        tool CreateRefund {
          input {
            amount: Int
          }

          output {
            id: String
          }

          errors { StripeError, NetworkError }

          implement {
            "ok"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert ["StripeError", "NetworkError"] = tool.errors
    end

    test "parses tool with annotated input fields" do
      source = """
      module M {
        tool CreateRefund {
          input {
            customer_id: String @description("Stripe customer ID")
            amount: Int @min(1) @max(100000)
          }

          output {
            id: String
          }

          implement {
            "ok"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      [cid, amount] = tool.input
      assert [%AST.Annotation{name: "description"}] = cid.annotations
      assert [%AST.Annotation{name: "min"}, %AST.Annotation{name: "max"}] = amount.annotations
    end

    test "parses tool with multiple output fields" do
      source = """
      module M {
        tool CreateRefund {
          input {
            amount: Int
          }

          output {
            id: String
            amount: Int
            status: String
          }

          implement {
            "ok"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert length(tool.output) == 3
    end

    test "parses tool with complex implement body" do
      source = """
      module M {
        tool CreateRefund {
          input {
            amount: Int
          }

          output {
            id: String
          }

          implement {
            let result = http.post("https://api.stripe.com/v1/refunds", "body")
            match result {
              Ok(r)  -> r
              Err(e) -> e
            }
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Let{}, %AST.Match{}]} = tool.implement
    end

    test "preserves source location on tool declaration" do
      source = """
      module M {
        tool MyTool {
          input { x: Int }
          output { y: Int }
          implement { 42 }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [tool]}} = parse(source)
      assert tool.meta.line == 2
    end

    test "parses tool mixed with other declarations" do
      source = """
      module M {
        capability http.out("api.example.com")

        fn helper() -> Int { 42 }

        tool MyTool {
          input { x: Int }
          output { y: Int }
          implement { 42 }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [cap, fn_decl, tool]}} = parse(source)
      assert %AST.Capability{} = cap
      assert %AST.Fn{name: "helper"} = fn_decl
      assert %AST.ToolDecl{name: "MyTool"} = tool
    end

    test "returns error for tool with missing input block" do
      source = """
      module M {
        tool MyTool {
          output { y: Int }
          implement { 42 }
        }
      }
      """

      assert {:error, [%Skein.Error{code: "E0001"}]} = parse(source)
    end

    test "returns error for tool with missing output block" do
      source = """
      module M {
        tool MyTool {
          input { x: Int }
          implement { 42 }
        }
      }
      """

      assert {:error, [%Skein.Error{code: "E0001"}]} = parse(source)
    end

    test "returns error for tool with missing implement block" do
      source = """
      module M {
        tool MyTool {
          input { x: Int }
          output { y: Int }
        }
      }
      """

      assert {:error, [%Skein.Error{code: "E0001"}]} = parse(source)
    end
  end

  # ------------------------------------------------------------------
  # tool.call, tool.list, tool.schema expressions (Phase 6c)
  # ------------------------------------------------------------------

  describe "parse/1 - tool expressions" do
    test "parses tool.call expression" do
      source = """
      module M {
        capability tool.use("MyTool")

        fn f(args: String) -> String {
          tool.call("MyTool", args)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "call"}
             } = call

      assert length(call.args) == 2
    end

    test "parses tool.list expression" do
      source = """
      module M {
        capability tool.use("MyTool")

        fn f() -> String {
          tool.list()
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "list"}
             } = call
    end

    test "parses tool.schema expression" do
      source = """
      module M {
        capability tool.use("MyTool")

        fn f() -> String {
          tool.schema("MyTool")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "schema"}
             } = call
    end

    test "parses tool.call result in let binding" do
      source = """
      module M {
        capability tool.use("CreateRefund")

        fn f(args: String) -> String {
          let result = tool.call("CreateRefund", args)
          result
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "result", value: %AST.Call{}}, _]} =
               fn_decl.body
    end
  end
end
