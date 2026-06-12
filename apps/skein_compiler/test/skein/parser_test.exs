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

    test "parses a match arm with a guard" do
      source = """
      module M {
        fn f(n: Int) -> String {
          match n {
            x if x > 0 -> "positive"
            _ -> "other"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [match]} = fn_decl.body
      assert [arm1, arm2] = match.arms

      assert %AST.MatchArm{pattern: %AST.Identifier{name: "x"}, guard: %AST.BinaryOp{op: :>}} =
               arm1

      assert %AST.MatchArm{pattern: %AST.Wildcard{}, guard: nil} = arm2
    end

    test "parses a guard on an enum variant pattern" do
      source = """
      module M {
        enum Size {
          Small
          Big(n: Int)
        }

        fn f(s: Size) -> String {
          match s {
            Big(n) if n > 100 && n < 1000 -> "medium"
            Big(n) -> "big"
            Small -> "small"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_enum, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [match]} = fn_decl.body
      assert [arm1, arm2, arm3] = match.arms
      assert %AST.MatchArm{guard: %AST.BinaryOp{op: :&&}} = arm1
      assert %AST.MatchArm{guard: nil} = arm2
      assert %AST.MatchArm{guard: nil} = arm3
    end

    test "'if' remains usable as an ordinary identifier" do
      source = """
      module M {
        fn f(if: Int) -> Int {
          if + 1
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert [%AST.Field{name: "if"}] = fn_decl.params
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

    test "interpolation segments are Identifier nodes with source positions" do
      source = "module M { fn f(name: String) -> String { \"Hello, \${name}!\" } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.StringLit{segments: segments}]} = fn_decl.body

      assert [
               {:literal, "Hello, "},
               {:interpolation, %AST.Identifier{name: "name", meta: meta}},
               {:literal, "!"}
             ] = segments

      assert meta.line == 1
      assert meta.col > 0
    end

    test "dotted interpolation segments are FieldAccess nodes" do
      source = "module M { fn f() -> String { \"id: \${req.params.id}\" } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.StringLit{segments: segments}]} = fn_decl.body

      assert [
               {:literal, "id: "},
               {:interpolation,
                %AST.FieldAccess{
                  subject: %AST.FieldAccess{
                    subject: %AST.Identifier{name: "req"},
                    field: "params"
                  },
                  field: "id"
                }}
             ] = segments
    end

    test "uppercase interpolation segments are Identifier nodes" do
      source = "module M { fn f() -> String { \"\${Foo}\" } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [%AST.StringLit{segments: segments}]} = fn_decl.body
      assert [{:interpolation, %AST.Identifier{name: "Foo"}}] = segments
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

    test "method!(args) parses as unwrap of the call" do
      source = "module M { fn f(id: String) -> Int { store.users.get!(id) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.UnaryOp{
                   op: :unwrap,
                   operand: %AST.Call{
                     target: %AST.FieldAccess{
                       subject: %AST.FieldAccess{
                         subject: %AST.Identifier{name: "store"},
                         field: "users"
                       },
                       field: "get"
                     },
                     args: [%AST.Identifier{name: "id"}]
                   }
                 }
               ]
             } = fn_decl.body
    end

    test "method?(args) parses as propagate of the call" do
      source = "module M { fn f(k: String) -> Int { memory.get?(k) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.UnaryOp{
                   op: :propagate,
                   operand: %AST.Call{args: [%AST.Identifier{name: "k"}]}
                 }
               ]
             } = fn_decl.body
    end

    test "chained postfix after bang-call continues the chain" do
      source = "module M { fn f(id: String) -> Int { store.users.get!(id).name } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.FieldAccess{
                   subject: %AST.UnaryOp{op: :unwrap, operand: %AST.Call{}},
                   field: "name"
                 }
               ]
             } = fn_decl.body
    end

    test "parses prefix minus on an integer literal" do
      source = "module M { fn f() -> Int { let x = -3 x } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Let{value: %AST.UnaryOp{op: :negate, operand: %AST.IntLit{value: 3}}},
                 %AST.Identifier{name: "x"}
               ]
             } = fn_decl.body
    end

    test "parses prefix minus on a float literal in call arguments" do
      source = "module M { fn f() -> Float { Float.round(-1.5, 0) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Call{
                   args: [
                     %AST.UnaryOp{op: :negate, operand: %AST.FloatLit{value: 1.5}},
                     %AST.IntLit{value: 0}
                   ]
                 }
               ]
             } = fn_decl.body
    end

    test "parses prefix minus on an identifier" do
      source = "module M { fn f(x: Int) -> Int { -x } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.UnaryOp{op: :negate, operand: %AST.Identifier{name: "x"}}
               ]
             } = fn_decl.body
    end

    test "parses a negative number as a map literal value" do
      source = "module M { fn f() -> Map[String, Int] { { number: -3 } } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.MapLit{
                   entries: [
                     {"number", %AST.UnaryOp{op: :negate, operand: %AST.IntLit{value: 3}}}
                   ]
                 }
               ]
             } = fn_decl.body
    end

    test "prefix minus binds tighter than binary addition" do
      source = "module M { fn f() -> Int { -2 + 3 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.BinaryOp{
                   op: :+,
                   left: %AST.UnaryOp{op: :negate, operand: %AST.IntLit{value: 2}},
                   right: %AST.IntLit{value: 3}
                 }
               ]
             } = fn_decl.body
    end

    test "prefix minus on a parenthesized expression negates the whole expression" do
      source = "module M { fn f() -> Int { -(2 + 3) } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.UnaryOp{
                   op: :negate,
                   operand: %AST.BinaryOp{
                     op: :+,
                     left: %AST.IntLit{value: 2},
                     right: %AST.IntLit{value: 3}
                   }
                 }
               ]
             } = fn_decl.body
    end

    test "binary minus still parses as subtraction" do
      source = "module M { fn f(a: Int) -> Int { a - 3 } }"

      assert {:ok, %AST.Module{declarations: [fn_decl]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.BinaryOp{
                   op: :-,
                   left: %AST.Identifier{name: "a"},
                   right: %AST.IntLit{value: 3}
                 }
               ]
             } = fn_decl.body
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

  describe "parse/1 - suspend expression" do
    test "parses suspend expression with string literal" do
      source = """
      agent A {
        on phase(Phase.Failed) -> {
          suspend("Requires human review")
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Suspend{
                   reason: %AST.StringLit{segments: [{:literal, "Requires human review"}]}
                 }
               ]
             } = handler.body
    end

    test "parses suspend expression with variable" do
      source = """
      agent A {
        on phase(Phase.Failed) -> {
          let reason = "Too many retries"
          suspend(reason)
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Let{name: "reason"},
                 %AST.Suspend{reason: %AST.Identifier{name: "reason"}}
               ]
             } = handler.body
    end

    test "parses suspend inside match arm" do
      source = """
      agent A {
        on start(severity: String) -> {
          match severity {
            "high" -> suspend("Needs escalation")
            _ -> stop()
          }
        }
      }
      """

      assert {:ok, %AST.Agent{handlers: [handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Match{arms: [arm1, _arm2]}]} = handler.body
      assert %AST.Suspend{reason: %AST.StringLit{}} = arm1.body
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
        capability tool.use(MyTool)

        fn f(args: String) -> String {
          tool.call(MyTool, args)
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
        capability tool.use(MyTool)

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
        capability tool.use(MyTool)

        fn f() -> String {
          tool.schema(MyTool)
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
        capability tool.use(CreateRefund)

        fn f(args: String) -> String {
          let result = tool.call(CreateRefund, args)
          result
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "result", value: %AST.Call{}}, _]} =
               fn_decl.body
    end
  end

  # ------------------------------------------------------------------
  # Type-parameterized calls: llm.json[T](...) (Phase 6c completion)
  # ------------------------------------------------------------------

  describe "parse/1 - type-parameterized calls" do
    test "parses llm.json[T](args) with type parameter" do
      source = """
      module M {
        type Decision {
          action: String
          amount: Int
        }

        capability model("anthropic", "claude-sonnet-4-5")

        fn decide(ticket: String) -> String {
          llm.json[Decision]("claude-sonnet-4-5", "Decide.", ticket)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_type, _cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body
      assert %AST.Call{type_param: %AST.TypeRef{name: "Decision"}} = call
      assert %AST.FieldAccess{subject: %AST.Identifier{name: "llm"}, field: "json"} = call.target
      assert length(call.args) == 3
    end

    test "parses type-parameterized call with parameterized type" do
      source = """
      module M {
        capability model("anthropic", "claude-sonnet-4-5")

        fn decide(ticket: String) -> String {
          llm.json[Result[String, String]]("claude-sonnet-4-5", "Decide.", ticket)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body
      assert %AST.Call{type_param: %AST.TypeRef{name: "Result", params: [_, _]}} = call
    end

    test "parses llm.json without type parameter (backward compat)" do
      source = """
      module M {
        capability model("anthropic", "claude-sonnet-4-5")

        fn decide(ticket: String) -> String {
          llm.json("claude-sonnet-4-5", "Decide.", ticket)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body
      assert %AST.Call{type_param: nil} = call
    end
  end

  # ------------------------------------------------------------------
  # Test declarations (Phase 7)
  # ------------------------------------------------------------------

  describe "parse/1 - test declarations" do
    test "parses a simple test declaration" do
      source = """
      module M {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "add returns correct sum" {
          assert add(2, 3) == 5
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_fn, test_decl]}} = parse(source)
      assert %AST.Test{description: "add returns correct sum"} = test_decl
      assert %AST.Block{expressions: [_assert_call]} = test_decl.body
    end

    test "parses test with multiple assertions" do
      source = """
      module M {
        fn double(x: Int) -> Int { x * 2 }

        test "double works" {
          assert double(1) == 2
          assert double(0) == 0
          assert double(5) == 10
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_fn, test_decl]}} = parse(source)
      assert %AST.Test{description: "double works"} = test_decl
      assert %AST.Block{expressions: exprs} = test_decl.body
      assert length(exprs) == 3
    end

    test "parses assert as a call to __assert__" do
      source = """
      module M {
        test "truth" {
          assert true
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [test_decl]}} = parse(source)
      assert %AST.Block{expressions: [assert_call]} = test_decl.body

      assert %AST.Call{
               target: %AST.Identifier{name: "__assert__"},
               args: [%AST.BoolLit{value: true}]
             } = assert_call
    end

    test "preserves source location on test" do
      source = """
      module M {
        test "my test" {
          assert true
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [test_decl]}} = parse(source)
      assert test_decl.meta.line == 2
    end

    test "parses test mixed with other declarations" do
      source = """
      module M {
        fn greet(name: String) -> String { "hello" }

        test "greet works" {
          assert greet("world") == "hello"
        }

        fn add(a: Int, b: Int) -> Int { a + b }

        test "add works" {
          assert add(1, 2) == 3
        }
      }
      """

      assert {:ok, %AST.Module{declarations: decls}} = parse(source)
      assert [%AST.Fn{}, %AST.Test{}, %AST.Fn{}, %AST.Test{}] = decls
    end
  end

  # ------------------------------------------------------------------
  # Scenario declarations (Phase 8a)
  # ------------------------------------------------------------------

  describe "parse/1 - scenario declarations" do
    test "parses a basic scenario with given and expect" do
      source = """
      module M {
        scenario "high-value refund" {
          given {
            amount: 50000
          }

          expect {
            assert amount > 100
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [scenario]}} = parse(source)
      assert %AST.Scenario{description: "high-value refund"} = scenario
      assert [{"amount", %AST.IntLit{value: 50000}}] = scenario.given_vars
      assert %AST.Block{expressions: [_assert]} = scenario.expect_body
    end

    test "parses a scenario with multiple given bindings" do
      source = """
      module M {
        scenario "multiple bindings" {
          given {
            x: 10
            y: 20
          }

          expect {
            assert x + y == 30
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [scenario]}} = parse(source)
      assert %AST.Scenario{} = scenario
      assert length(scenario.given_vars) == 2
      assert {"x", %AST.IntLit{value: 10}} = Enum.at(scenario.given_vars, 0)
      assert {"y", %AST.IntLit{value: 20}} = Enum.at(scenario.given_vars, 1)
    end

    test "parses a scenario with multiple assertions" do
      source = """
      module M {
        scenario "many checks" {
          given {
            n: 42
          }

          expect {
            assert n > 0
            assert n == 42
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [scenario]}} = parse(source)
      assert %AST.Block{expressions: [_, _]} = scenario.expect_body
    end

    test "parses a scenario with string values in given" do
      source = """
      module M {
        scenario "string inputs" {
          given {
            name: "world"
          }

          expect {
            assert name == "world"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [scenario]}} = parse(source)
      {"name", %AST.StringLit{}} = hd(scenario.given_vars)
    end

    test "scenario preserves source location" do
      source = """
      module M {
        scenario "located" {
          given {
            x: 1
          }

          expect {
            assert x == 1
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [scenario]}} = parse(source)
      assert scenario.meta.line == 2
    end

    test "scenario mixed with functions and tests" do
      source = """
      module M {
        fn add(a: Int, b: Int) -> Int { a + b }

        test "basic test" {
          assert add(1, 2) == 3
        }

        scenario "scenario test" {
          given {
            x: 5
          }

          expect {
            assert add(x, 1) == 6
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl, test_decl, scenario_decl]}} = parse(source)
      assert %AST.Fn{} = fn_decl
      assert %AST.Test{} = test_decl
      assert %AST.Scenario{} = scenario_decl
    end
  end

  # ------------------------------------------------------------------
  # Golden declarations (Phase 8a)
  # ------------------------------------------------------------------

  describe "parse/1 - golden declarations" do
    test "parses a basic golden test" do
      source = """
      module M {
        golden "refund flow" from trace "traces/refund.json" {
          assert true
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [golden]}} = parse(source)
      assert %AST.Golden{description: "refund flow"} = golden
      assert golden.trace_file == "traces/refund.json"
      assert %AST.Block{expressions: [_assert]} = golden.body
    end

    test "parses a golden test with multiple assertions" do
      source = """
      module M {
        golden "trace check" from trace "data/trace.json" {
          assert true
          assert 1 == 1
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [golden]}} = parse(source)
      assert %AST.Golden{description: "trace check"} = golden
      assert golden.trace_file == "data/trace.json"
      assert %AST.Block{expressions: [_, _]} = golden.body
    end

    test "golden preserves source location" do
      source = """
      module M {
        golden "located" from trace "t.json" {
          assert true
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [golden]}} = parse(source)
      assert golden.meta.line == 2
    end

    test "golden mixed with other declarations" do
      source = """
      module M {
        fn ok() -> Bool { true }

        test "unit" { assert ok() }

        golden "trace" from trace "t.json" {
          assert ok()
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [fn_decl, test_decl, golden_decl]}} = parse(source)
      assert %AST.Fn{} = fn_decl
      assert %AST.Test{} = test_decl
      assert %AST.Golden{} = golden_decl
    end
  end

  # ------------------------------------------------------------------
  # Queue handler declarations (Phase 8e)
  # ------------------------------------------------------------------

  describe "parse/1 - queue handler declarations" do
    test "parses a queue handler" do
      source = """
      module M {
        capability queue.consume
        handler queue "order-events" (msg) -> {
          let data = msg
          respond.json(200, data)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Handler{source: "queue", method: nil, route: "order-events", param: "msg"} =
               handler

      assert %AST.Block{} = handler.body
    end

    test "parses queue handler with different queue name" do
      source = """
      module M {
        capability queue.consume
        handler queue "user-notifications" (message) -> {
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.source == "queue"
      assert handler.route == "user-notifications"
      assert handler.param == "message"
    end

    test "parses multiple queue handlers" do
      source = """
      module M {
        capability queue.consume

        handler queue "events-a" (msg) -> {
          respond.json(200, "a")
        }

        handler queue "events-b" (msg) -> {
          respond.json(200, "b")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, h1, h2]}} = parse(source)
      assert %AST.Handler{source: "queue", route: "events-a"} = h1
      assert %AST.Handler{source: "queue", route: "events-b"} = h2
    end

    test "parses queue handler alongside HTTP handlers" do
      source = """
      module M {
        capability http.in
        capability queue.consume

        handler http GET "/status" (req) -> {
          respond.json(200, "ok")
        }

        handler queue "events" (msg) -> {
          respond.json(200, msg)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap1, _cap2, http_handler, queue_handler]}} =
               parse(source)

      assert http_handler.source == "http"
      assert queue_handler.source == "queue"
    end
  end

  # ------------------------------------------------------------------
  # Schedule handler declarations (Phase 8e)
  # ------------------------------------------------------------------

  describe "parse/1 - schedule handler declarations" do
    test "parses a schedule handler with cron expression" do
      source = """
      module M {
        capability schedule.trigger
        handler schedule "*/5 * * * *" () -> {
          respond.json(200, "tick")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Handler{source: "schedule", method: nil, route: "*/5 * * * *", param: nil} =
               handler

      assert %AST.Block{} = handler.body
    end

    test "parses schedule handler with hourly cron" do
      source = """
      module M {
        capability schedule.trigger
        handler schedule "0 * * * *" () -> {
          respond.json(200, "hourly")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.route == "0 * * * *"
    end

    test "parses schedule handler with daily cron" do
      source = """
      module M {
        capability schedule.trigger
        handler schedule "0 0 * * *" () -> {
          respond.json(200, "daily")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.route == "0 0 * * *"
    end

    test "parses multiple schedule handlers" do
      source = """
      module M {
        capability schedule.trigger

        handler schedule "*/5 * * * *" () -> {
          respond.json(200, "five_min")
        }

        handler schedule "0 * * * *" () -> {
          respond.json(200, "hourly")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, h1, h2]}} = parse(source)
      assert %AST.Handler{source: "schedule", route: "*/5 * * * *"} = h1
      assert %AST.Handler{source: "schedule", route: "0 * * * *"} = h2
    end

    test "parses all handler types together" do
      source = """
      module M {
        capability http.in
        capability queue.consume
        capability schedule.trigger

        handler http GET "/health" (req) -> {
          respond.json(200, "ok")
        }

        handler queue "events" (msg) -> {
          respond.json(200, msg)
        }

        handler schedule "*/10 * * * *" () -> {
          respond.json(200, "tick")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_c1, _c2, _c3, h1, h2, h3]}} = parse(source)
      assert h1.source == "http"
      assert h2.source == "queue"
      assert h3.source == "schedule"
    end
  end

  # ------------------------------------------------------------------
  # Tool identifier references (capability-as-import)
  # ------------------------------------------------------------------

  describe "parse/1 - tool identifier references" do
    test "parses capability tool.use with identifier param" do
      source = """
      module M {
        capability tool.use(CreateRefund)
      }
      """

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "tool.use"} = cap
      assert [%AST.ToolRef{name: "CreateRefund"}] = cap.params
    end

    test "parses capability tool.use with dotted identifier param" do
      source = """
      module M {
        capability tool.use(Stripe.CreateRefund)
      }
      """

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "tool.use"} = cap

      assert [%AST.ToolRef{name: "Stripe.CreateRefund"}] = cap.params
    end

    test "parses capability tool.use with multiple identifier params" do
      source = """
      module M {
        capability tool.use(CreateRefund, GetBalance)
      }
      """

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "tool.use"} = cap
      assert [%AST.ToolRef{name: "CreateRefund"}, %AST.ToolRef{name: "GetBalance"}] = cap.params
    end

    test "parses capability tool.use with multiple dotted identifier params" do
      source = """
      module M {
        capability tool.use(Stripe.CreateRefund, Stripe.GetBalance)
      }
      """

      assert {:ok, %AST.Module{declarations: [cap]}} = parse(source)
      assert %AST.Capability{kind: "tool.use"} = cap

      assert [%AST.ToolRef{name: "Stripe.CreateRefund"}, %AST.ToolRef{name: "Stripe.GetBalance"}] =
               cap.params
    end

    test "parses tool.call with identifier first arg" do
      source = """
      module M {
        capability tool.use(MyTool)

        fn f(args: String) -> String {
          tool.call(MyTool, args)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "call"}
             } = call

      assert [%AST.ToolRef{name: "MyTool"}, %AST.Identifier{name: "args"}] = call.args
    end

    test "parses tool.call with dotted identifier first arg" do
      source = """
      module M {
        capability tool.use(Stripe.CreateRefund)

        fn f(args: String) -> String {
          tool.call(Stripe.CreateRefund, args)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "call"}
             } = call

      [tool_ref | _] = call.args
      assert %AST.ToolRef{name: "Stripe.CreateRefund"} = tool_ref
    end

    test "parses tool.schema with identifier arg" do
      source = """
      module M {
        capability tool.use(MyTool)

        fn f() -> String {
          tool.schema(MyTool)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)
      assert %AST.Block{expressions: [call]} = fn_decl.body

      assert %AST.Call{
               target: %AST.FieldAccess{subject: %AST.Identifier{name: "tool"}, field: "schema"}
             } = call

      assert [%AST.ToolRef{name: "MyTool"}] = call.args
    end

    test "parses tool.call identifier result in let binding" do
      source = """
      module M {
        capability tool.use(CreateRefund)

        fn f(args: String) -> String {
          let result = tool.call(CreateRefund, args)
          result
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, fn_decl]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "result", value: %AST.Call{}}, _]} =
               fn_decl.body
    end
  end

  # ------------------------------------------------------------------
  # Supervisor declarations
  # ------------------------------------------------------------------

  describe "supervisor declarations" do
    test "parses supervisor with a single child" do
      source = """
      module M {
        supervisor Main {
          child HttpServer
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert %AST.Supervisor{name: "Main"} = sup
      assert length(sup.children) == 1
      [child] = sup.children
      assert %AST.Child{target: "HttpServer", args: [], options: %{}} = child
    end

    test "parses supervisor with child options" do
      source = """
      module M {
        supervisor Main {
          child HttpServer { restart: permanent }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      [child] = sup.children
      assert child.target == "HttpServer"
      assert child.options == %{"restart" => "permanent"}
    end

    test "parses supervisor with child arguments" do
      source = """
      module M {
        supervisor Main {
          child AgentPool(RefundAgent)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      [child] = sup.children
      assert child.target == "AgentPool"
      assert child.args == ["RefundAgent"]
    end

    test "parses supervisor with child arguments and options" do
      source = """
      module M {
        supervisor Main {
          child AgentPool(RefundAgent) { max: 5000, restart: transient }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      [child] = sup.children
      assert child.target == "AgentPool"
      assert child.args == ["RefundAgent"]
      assert child.options == %{"max" => 5000, "restart" => "transient"}
    end

    test "parses supervisor strategy" do
      source = """
      module M {
        supervisor Main {
          child HttpServer
          strategy: one_for_one
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert sup.strategy == :one_for_one
    end

    test "parses supervisor max_restarts" do
      source = """
      module M {
        supervisor Main {
          child HttpServer
          max_restarts: 10 per 60s
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert sup.max_restarts == {10, 60}
    end

    test "parses full supervisor with all options" do
      source = """
      module M {
        supervisor Main {
          child HttpServer { restart: permanent }
          child AgentPool(RefundAgent) { max: 5000, restart: transient }
          strategy: one_for_one
          max_restarts: 10 per 60s
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert sup.name == "Main"
      assert length(sup.children) == 2
      assert sup.strategy == :one_for_one
      assert sup.max_restarts == {10, 60}

      [c1, c2] = sup.children
      assert c1.target == "HttpServer"
      assert c1.options == %{"restart" => "permanent"}
      assert c2.target == "AgentPool"
      assert c2.args == ["RefundAgent"]
      assert c2.options == %{"max" => 5000, "restart" => "transient"}
    end

    test "parses supervisor with one_for_all strategy" do
      source = """
      module M {
        supervisor Main {
          child HttpServer
          strategy: one_for_all
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert sup.strategy == :one_for_all
    end

    test "parses supervisor with rest_for_one strategy" do
      source = """
      module M {
        supervisor Main {
          child HttpServer
          strategy: rest_for_one
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [sup]}} = parse(source)
      assert sup.strategy == :rest_for_one
    end
  end

  # ------------------------------------------------------------------
  # Topic handler declarations
  # ------------------------------------------------------------------

  describe "parse/1 - topic handler declarations" do
    test "parses a topic handler" do
      source = """
      module M {
        capability topic.consume("order.events")
        handler topic "order.events" (msg) -> {
          let data = msg
          respond.json(200, data)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Handler{source: "topic", method: nil, route: "order.events", param: "msg"} =
               handler

      assert %AST.Block{} = handler.body
    end

    test "parses topic handler with different topic name" do
      source = """
      module M {
        capability topic.consume("user.signups")
        handler topic "user.signups" (event) -> {
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert handler.source == "topic"
      assert handler.route == "user.signups"
      assert handler.param == "event"
    end

    test "parses multiple topic handlers" do
      source = """
      module M {
        capability topic.consume("events-a")

        handler topic "events-a" (msg) -> {
          respond.json(200, "a")
        }

        handler topic "events-b" (msg) -> {
          respond.json(200, "b")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, h1, h2]}} = parse(source)
      assert %AST.Handler{source: "topic", route: "events-a"} = h1
      assert %AST.Handler{source: "topic", route: "events-b"} = h2
    end

    test "parses topic handler alongside other handler types" do
      source = """
      module M {
        capability http.in
        capability queue.consume
        capability topic.consume("notifications")

        handler http GET "/status" (req) -> {
          respond.json(200, "ok")
        }

        handler queue "jobs" (msg) -> {
          respond.json(200, msg)
        }

        handler topic "notifications" (event) -> {
          respond.json(200, event)
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_c1, _c2, _c3, h1, h2, h3]}} = parse(source)
      assert h1.source == "http"
      assert h2.source == "queue"
      assert h3.source == "topic"
    end

    test "rejects unknown handler source" do
      source = """
      module M {
        handler unknown "test" (msg) -> {
          respond.json(200, "ok")
        }
      }
      """

      assert {:error, errors} = parse(source)
      assert Enum.any?(errors, fn e -> e.message =~ "Unknown handler source" end)
    end
  end

  describe "parse/1 - idempotent expression" do
    test "parses idempotent with string literal" do
      source = """
      module M {
        capability queue.consume
        handler queue "jobs" (msg) -> {
          idempotent("unique-key-123")
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Idempotent{
                   key: %AST.StringLit{segments: [{:literal, "unique-key-123"}]}
                 },
                 _respond
               ]
             } = handler.body
    end

    test "parses idempotent with variable reference" do
      source = """
      module M {
        capability queue.consume
        handler queue "jobs" (msg) -> {
          let key = "abc"
          idempotent(key)
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Let{name: "key"},
                 %AST.Idempotent{key: %AST.Identifier{name: "key"}},
                 _respond
               ]
             } = handler.body
    end

    test "parses idempotent with field access" do
      source = """
      module M {
        capability queue.consume
        handler queue "jobs" (msg) -> {
          idempotent(msg.id)
          respond.json(200, "ok")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.Idempotent{
                   key: %AST.FieldAccess{
                     subject: %AST.Identifier{name: "msg"},
                     field: "id"
                   }
                 },
                 _respond
               ]
             } = handler.body
    end

    test "preserves source location for idempotent" do
      source = """
      module M {
        capability queue.consume
        handler queue "jobs" (msg) -> {
          idempotent("key")
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [_cap, handler]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Idempotent{meta: meta}]} = handler.body
      assert meta.line == 4
    end
  end

  describe "map literals" do
    test "parses empty map literal" do
      source = """
      module M {
        fn empty() -> Map[String, Int] {
          {}
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.MapLit{entries: []}]} = f.body
    end

    test "parses single-entry map literal" do
      source = """
      module M {
        fn one() -> Map[String, Int] {
          { name: "Alice" }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.MapLit{entries: entries}]} = f.body
      assert [{"name", %AST.StringLit{}}] = entries
    end

    test "parses multi-entry map literal" do
      source = """
      module M {
        fn user() -> Map[String, String] {
          { name: "Alice", age: 30, active: true }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.MapLit{entries: entries}]} = f.body

      assert [
               {"name", %AST.StringLit{}},
               {"age", %AST.IntLit{value: 30}},
               {"active", %AST.BoolLit{value: true}}
             ] = entries
    end

    test "parses map literal with expression values" do
      source = """
      module M {
        fn make(name: String) -> Map[String, String] {
          { name: name, greeting: "hello" }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.MapLit{entries: entries}]} = f.body
      assert [{"name", %AST.Identifier{name: "name"}}, {"greeting", %AST.StringLit{}}] = entries
    end

    test "parses nested map literal" do
      source = """
      module M {
        fn nested() -> Map[String, Map[String, Int]] {
          { user: { name: "Alice" } }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)

      assert %AST.Block{
               expressions: [
                 %AST.MapLit{
                   entries: [{"user", %AST.MapLit{entries: [{"name", %AST.StringLit{}}]}}]
                 }
               ]
             } = f.body
    end

    test "map literal preserves source location" do
      source = """
      module M {
        fn m() -> Map[String, Int] {
          { x: 1 }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.MapLit{meta: meta}]} = f.body
      assert meta.line == 3
    end

    test "block still works when not a map literal" do
      source = """
      module M {
        fn f(x: Int) -> Int {
          let y = x + 1
          y
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Let{}, %AST.Identifier{}]} = f.body
    end
  end

  describe "contextual keywords as variable names" do
    test "input can be used as a variable name" do
      source = """
      module M {
        fn process(data: String) -> String {
          let input = data
          input
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "input"}, %AST.Identifier{name: "input"}]} =
               f.body
    end

    test "state can be used as a variable name" do
      source = """
      module M {
        fn process(x: Int) -> Int {
          let state = x + 1
          state
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "state"}, %AST.Identifier{name: "state"}]} =
               f.body
    end

    test "output can be used as a variable name" do
      source = """
      module M {
        fn process(x: Int) -> Int {
          let output = x
          output
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [f]}} = parse(source)

      assert %AST.Block{expressions: [%AST.Let{name: "output"}, %AST.Identifier{name: "output"}]} =
               f.body
    end

    test "input still works as keyword in tool declarations" do
      source = """
      module M {
        tool MyTool {
          description: "A tool"
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
      assert %AST.ToolDecl{input: [%AST.Field{name: "name"}]} = tool
    end
  end

  describe "structured error contract — fix_code" do
    # CLAUDE.md design constraint #5: every compiler error carries fix_hint
    # AND fix_code so agents can apply fixes mechanically.

    test "expect/3 'expected token' errors include insertable fix_code" do
      # Missing closing brace on the module
      assert {:error, [error]} = parse("module M { fn f() -> Int { 1 }")
      assert error.fix_hint != nil
      assert error.fix_code == "}"
    end

    test "missing arrow in function declaration includes fix_code" do
      assert {:error, [error]} = parse("module M { fn f() Int { 1 } }")
      assert error.fix_code == "->"
    end

    test "unexpected declaration token includes fix_code" do
      assert {:error, [error]} = parse("module M { 42 }")
      assert error.code == "E0001"
      assert error.fix_code != nil
    end

    test "unknown handler source includes fix_code" do
      assert {:error, [error]} =
               parse("module M { handler smoke \"/x\" (req) -> { 1 } }")

      assert error.fix_code != nil
    end

    test "tool missing input block includes fix_code" do
      source = """
      module M {
        tool T {
          description: "x"
          output { result: String }
          implement { "done" }
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "input"
      assert error.fix_code == "input { field: Type }"
    end

    test "unexpected_token_error descriptions derive code snippets" do
      # Missing route string after the HTTP method
      assert {:error, [error]} =
               parse("module M { handler http GET (req) -> { 1 } }")

      assert error.fix_code == "\"/path\""
    end
  end

  describe "targeted missing-token errors" do
    # Issue #83: a known section/entry name followed by the wrong token must
    # name the actual problem (the missing token), not re-list alternatives.

    test "tool description missing its colon gets a targeted error" do
      source = """
      module M {
        tool T {
          description "creates a refund"
          input { amount: Int }
          output { ok: Bool }
          implement { "done" }
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.code == "E0001"
      assert error.message =~ "Missing ':' after 'description'"
      assert error.fix_hint =~ "':'"
      assert error.fix_code == ":"
      # Points at the section name on line 3
      assert error.location.line == 3
    end

    test "tool input missing its brace gets a targeted error" do
      source = """
      module M {
        tool T {
          input amount: Int
          output { ok: Bool }
          implement { "done" }
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Missing '{' after 'input'"
      assert error.fix_code == "{"
    end

    test "tool output missing its brace gets a targeted error" do
      source = """
      module M {
        tool T {
          input { amount: Int }
          output ok: Bool
          implement { "done" }
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Missing '{' after 'output'"
      assert error.fix_code == "{"
    end

    test "tool errors section missing its brace gets a targeted error" do
      source = """
      module M {
        tool T {
          input { amount: Int }
          output { ok: Bool }
          errors NotFound
          implement { "done" }
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Missing '{' after 'errors'"
      assert error.fix_code == "{"
    end

    test "unknown tool section still lists the alternatives" do
      source = """
      module M {
        tool T {
          banana: "yellow"
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "tool section"
      assert error.message =~ "description, input, output, errors, implement"
    end

    test "supervisor strategy missing its colon gets a targeted error" do
      source = """
      module M {
        supervisor Pool {
          child Worker
          strategy one_for_one
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Missing ':' after 'strategy'"
      assert error.fix_code == ":"
    end

    test "invalid supervisor strategy value names the valid strategies" do
      source = """
      module M {
        supervisor Pool {
          child Worker
          strategy: round_robin
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "one_for_one, one_for_all, rest_for_one"
      assert error.fix_code == "one_for_one"
    end

    test "supervisor max_restarts missing its colon gets a targeted error" do
      source = """
      module M {
        supervisor Pool {
          child Worker
          max_restarts 3 per 60s
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Missing ':' after 'max_restarts'"
      assert error.fix_code == ":"
    end

    test "malformed max_restarts value names the expected form" do
      source = """
      module M {
        supervisor Pool {
          child Worker
          max_restarts: 3 every 60s
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "N per Ns"
      assert error.fix_code == "3 per 60s"
    end

    test "field declaration missing its colon names the ':' token" do
      source = """
      module M {
        type User {
          name String
        }
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Expected ':'"
      assert error.fix_hint =~ "':'"
      assert error.fix_code == ":"
    end

    test "agent state block missing its brace names the '{' token" do
      source = """
      agent A {
        state
          count: Int
      }
      """

      assert {:error, [error]} = parse(source)
      assert error.message =~ "Expected '{'"
      assert error.fix_code == "{"
    end
  end
end
