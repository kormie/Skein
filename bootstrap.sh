#!/bin/bash
# Skein Project Bootstrap Script
# Run this to create the initial Elixir umbrella project structure.
#
# Prerequisites:
#   - Erlang/OTP 27+
#   - Elixir 1.17+
#   - Git
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh

set -euo pipefail

PROJECT_DIR="skein"

echo "🧶 Bootstrapping Skein project..."

# Check prerequisites
command -v elixir >/dev/null 2>&1 || { echo "❌ Elixir is required. Install from https://elixir-lang.org/install.html"; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "❌ Mix is required (comes with Elixir)"; exit 1; }

ELIXIR_VERSION=$(elixir --version | grep "Elixir" | awk '{print $2}')
echo "  Elixir version: $ELIXIR_VERSION"

# Create umbrella project
echo "  Creating umbrella project..."
mix new $PROJECT_DIR --umbrella
cd $PROJECT_DIR

# Create apps
echo "  Creating skein_compiler app..."
cd apps
mix new skein_compiler
cd skein_compiler
cd ../..

echo "  Creating skein_runtime app..."
cd apps
mix new skein_runtime --sup
cd skein_runtime
cd ../..

echo "  Creating skein_cli app..."
cd apps
mix new skein_cli
cd skein_cli
cd ../..

# Create directory structure
echo "  Creating directory structure..."

# Compiler directories
mkdir -p apps/skein_compiler/lib/skein/{analyzer,codegen}
mkdir -p apps/skein_compiler/test/skein/{lexer,parser,analyzer,codegen}

# Runtime directories
mkdir -p apps/skein_runtime/lib/skein/runtime/{llm,store}
mkdir -p apps/skein_runtime/test/skein/runtime

# CLI directories
mkdir -p apps/skein_cli/lib/skein/cli

# Doc and spec directories
mkdir -p docs
mkdir -p examples
mkdir -p spec/{lexer,parser,analyzer,codegen}

# Copy documentation (if present in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/docs" ]; then
  echo "  Copying documentation..."
  cp "$SCRIPT_DIR/docs/"*.md docs/ 2>/dev/null || true
fi
if [ -f "$SCRIPT_DIR/CLAUDE.md" ]; then
  cp "$SCRIPT_DIR/CLAUDE.md" .
fi

# Create example Skein files
echo "  Creating example Skein files..."

cat > examples/hello.skein << 'SKEIN'
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
SKEIN

cat > examples/http_service.skein << 'SKEIN'
module UserService {
  capability http.in
  capability store.table("users")

  type User {
    id: Uuid @primary
    email: Email @unique
    name: String
    created_at: Instant
  }

  handler http GET "/users/:id" (req) -> {
    let id = Uuid.parse!(req.params.id)
    let user = store.users.get(id)
    match user {
      Ok(u)         -> respond.json(200, u)
      Err(NotFound) -> respond.json(404, { "error": "not found" })
    }
  }

  handler http POST "/users" (req) -> {
    let input = req.json[User]?
    let user = store.users.put(input)!
    respond.json(201, user)
  }
}
SKEIN

cat > examples/refund_agent.skein << 'SKEIN'
module RefundService {
  capability model("anthropic", "claude-sonnet-4-5")
  capability memory.kv("refund_sessions")
  capability tool.use("Stripe.CreateRefund")
  capability store.table("tickets")

  type RefundDecision {
    action: String @one_of(["approve", "deny"])
    amount: Int @min(0)
    reason: String
  }

  agent RefundAgent {
    state {
      ticket_id: Uuid
      customer_id: String
      phase: Phase
    }

    enum Phase {
      Analyze  -> [Refund, Done]
      Refund   -> [Done, Failed]
      Failed   -> [Analyze]
      Done     -> []
    }

    on start(ticket_id: Uuid, customer_id: String) -> {
      transition(Phase.Analyze)
    }

    on phase(Phase.Analyze) -> {
      let ticket = store.tickets.get!(state.ticket_id)
      let decision = llm.json[RefundDecision](
        model: "claude-sonnet-4-5",
        system: "Decide if this ticket warrants a refund.",
        input: ticket
      )

      match decision {
        Ok(d) -> {
          memory.put("decision", d)
          match d.action {
            "approve" -> transition(Phase.Refund)
            "deny"    -> transition(Phase.Done)
          }
        }
        Err(e) -> transition(Phase.Failed)
      }
    }

    on phase(Phase.Refund) -> {
      let d = memory.get!("decision")
      let result = tool.call("Stripe.CreateRefund", {
        customer_id: state.customer_id,
        amount: d.amount
      })

      match result {
        Ok(refund) -> {
          emit RefundIssued { ticket_id: state.ticket_id, refund_id: refund.id }
          transition(Phase.Done)
        }
        Err(e) -> transition(Phase.Failed)
      }
    }

    on phase(Phase.Failed) -> {
      suspend(reason: "Requires human review")
    }
  }
}
SKEIN

# Write root mix.exs with proper dependencies
cat > mix.exs << 'MIXFILE'
defmodule Skein.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      "skein.compile": ["run -e 'Skein.CLI.compile(System.argv())'"],
      "skein.spec": ["run -e 'Skein.CLI.spec(System.argv())'"]
    ]
  end
end
MIXFILE

# Write skein_compiler mix.exs with dependencies
cat > apps/skein_compiler/mix.exs << 'MIXFILE'
defmodule SkeinCompiler.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_compiler,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :compiler]
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
MIXFILE

# Write skein_runtime mix.exs with dependencies
cat > apps/skein_runtime/mix.exs << 'MIXFILE'
defmodule SkeinRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SkeinRuntime.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_state_machine, "~> 3.0"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_api, "~> 1.3"}
    ]
  end
end
MIXFILE

# Write skein_cli mix.exs
cat > apps/skein_cli/mix.exs << 'MIXFILE'
defmodule SkeinCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :skein_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:skein_compiler, in_umbrella: true},
      {:skein_runtime, in_umbrella: true},
      {:optimus, "~> 0.5"}
    ]
  end
end
MIXFILE

# Create stub modules for Phase 1

cat > apps/skein_compiler/lib/skein_compiler.ex << 'ELIXIR'
defmodule Skein.Compiler do
  @moduledoc """
  Main entry point for the Skein compiler.

  Orchestrates the compilation pipeline:
  Source (.skein) -> Lexer -> Parser -> Analyzer -> CodeGen -> BEAM bytecode
  """

  alias Skein.Lexer
  alias Skein.Parser
  alias Skein.Analyzer
  alias Skein.CodeGen.CoreErlang

  @spec compile_file(String.t()) :: {:ok, module()} | {:error, [Skein.Error.t()]}
  def compile_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- Analyzer.analyze(ast),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"#{path}", beam_binary)
    end
  end

  @spec compile_string(String.t()) :: {:ok, module()} | {:error, [Skein.Error.t()]}
  def compile_string(source) do
    with {:ok, tokens} <- Lexer.tokenize(source),
         {:ok, ast} <- Parser.parse(tokens),
         {:ok, annotated_ast} <- Analyzer.analyze(ast),
         {:ok, beam_binary} <- CoreErlang.generate(annotated_ast) do
      module_name = module_name_from_ast(annotated_ast)
      :code.load_binary(module_name, ~c"nofile", beam_binary)
    end
  end

  defp module_name_from_ast(%Skein.AST.Module{name: name}), do: String.to_atom("Elixir.Skein.User.#{name}")
  defp module_name_from_ast(_), do: :skein_unknown
end
ELIXIR

cat > apps/skein_compiler/lib/skein/ast.ex << 'ELIXIR'
defmodule Skein.AST do
  @moduledoc """
  AST node definitions for Skein.

  Every node carries a `meta` field with source location:
  %{line: integer, col: integer, file: string}
  """

  # Top-level declarations
  defmodule Module,     do: defstruct [:name, :capabilities, :declarations, :meta]
  defmodule Capability, do: defstruct [:kind, :params, :meta]
  defmodule Fn,         do: defstruct [:name, :params, :return_type, :body, :meta]
  defmodule TypeDecl,   do: defstruct [:name, :fields, :constraints, :meta]
  defmodule EnumDecl,   do: defstruct [:name, :variants, :transitions, :meta]
  defmodule Handler,    do: defstruct [:source, :method, :route, :param, :body, :meta]
  defmodule Agent,      do: defstruct [:name, :capabilities, :state, :phases, :handlers, :fns, :meta]
  defmodule ToolDecl,   do: defstruct [:name, :description, :input, :output, :errors, :policy, :implement, :meta]
  defmodule Supervisor, do: defstruct [:name, :children, :strategy, :max_restarts, :meta]
  defmodule Test,       do: defstruct [:description, :body, :meta]

  # Type nodes
  defmodule TypeRef,    do: defstruct [:name, :params, :meta]
  defmodule Field,      do: defstruct [:name, :type, :annotations, :meta]
  defmodule Variant,    do: defstruct [:name, :fields, :transitions, :meta]
  defmodule Annotation, do: defstruct [:name, :value, :meta]

  # Expression nodes
  defmodule Let,         do: defstruct [:name, :type, :value, :meta]
  defmodule Match,       do: defstruct [:subject, :arms, :meta]
  defmodule MatchArm,    do: defstruct [:pattern, :guard, :body, :meta]
  defmodule Call,        do: defstruct [:target, :args, :meta]
  defmodule Pipe,        do: defstruct [:left, :right, :meta]
  defmodule FieldAccess, do: defstruct [:subject, :field, :meta]
  defmodule BinaryOp,    do: defstruct [:op, :left, :right, :meta]
  defmodule UnaryOp,     do: defstruct [:op, :operand, :meta]
  defmodule StringLit,   do: defstruct [:segments, :meta]
  defmodule IntLit,      do: defstruct [:value, :meta]
  defmodule FloatLit,    do: defstruct [:value, :meta]
  defmodule BoolLit,     do: defstruct [:value, :meta]
  defmodule ListLit,     do: defstruct [:elements, :meta]
  defmodule MapLit,      do: defstruct [:entries, :meta]
  defmodule Block,       do: defstruct [:expressions, :meta]
  defmodule Identifier,  do: defstruct [:name, :meta]
  defmodule FnRef,       do: defstruct [:name, :meta]
  defmodule Transition,  do: defstruct [:phase, :meta]
  defmodule Emit,        do: defstruct [:event_name, :fields, :meta]
  defmodule Respond,     do: defstruct [:method, :args, :meta]
  defmodule Wildcard,    do: defstruct [:meta]
end
ELIXIR

cat > apps/skein_compiler/lib/skein/error.ex << 'ELIXIR'
defmodule Skein.Error do
  @moduledoc """
  Structured compiler error.

  All errors are JSON-serializable and include machine-readable fix hints
  for LLM-driven code correction loops.
  """

  @derive Jason.Encoder
  defstruct [:code, :severity, :message, :location, :context, :fix_hint, :fix_code]

  @type t :: %__MODULE__{
    code: String.t(),
    severity: :error | :warning,
    message: String.t(),
    location: %{file: String.t(), line: pos_integer(), col: pos_integer()},
    context: String.t() | nil,
    fix_hint: String.t() | nil,
    fix_code: String.t() | nil
  }

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    Jason.encode!(error)
  end

  @spec to_json_list([t()]) :: String.t()
  def to_json_list(errors) when is_list(errors) do
    Jason.encode!(%{errors: errors})
  end
end
ELIXIR

cat > apps/skein_compiler/lib/skein/lexer.ex << 'ELIXIR'
defmodule Skein.Lexer do
  @moduledoc """
  Tokenizer for Skein source code.

  Converts UTF-8 source text into a list of {token_type, location, value?} tuples.
  Location is {line, col}, both 1-indexed.
  """

  @spec tokenize(String.t()) :: {:ok, list()} | {:error, [Skein.Error.t()]}
  def tokenize(source) do
    # TODO: Implement lexer
    # Phase 1 target: keywords, identifiers, literals, operators, delimiters
    {:error, [%Skein.Error{
      code: "E0001",
      severity: :error,
      message: "Lexer not yet implemented",
      location: %{file: "unknown", line: 1, col: 1}
    }]}
  end
end
ELIXIR

cat > apps/skein_compiler/lib/skein/parser.ex << 'ELIXIR'
defmodule Skein.Parser do
  @moduledoc """
  Recursive descent parser for Skein.

  Converts a token list into an AST. Uses synchronization-point error
  recovery to report multiple errors per compilation.
  """

  @spec parse(list()) :: {:ok, Skein.AST.Module.t()} | {:error, [Skein.Error.t()]}
  def parse(tokens) do
    # TODO: Implement parser
    {:error, [%Skein.Error{
      code: "E0001",
      severity: :error,
      message: "Parser not yet implemented",
      location: %{file: "unknown", line: 1, col: 1}
    }]}
  end
end
ELIXIR

cat > apps/skein_compiler/lib/skein/analyzer.ex << 'ELIXIR'
defmodule Skein.Analyzer do
  @moduledoc """
  Semantic analyzer for Skein AST.

  Runs multiple passes:
  1. Name resolution (build symbol table, resolve identifiers)
  2. Type checking (verify types at boundaries, check match exhaustiveness)
  3. Capability checking (verify effect calls have covering capabilities)
  4. Transition checking (verify agent phase transitions are valid)
  """

  @spec analyze(Skein.AST.Module.t()) :: {:ok, Skein.AST.Module.t()} | {:error, [Skein.Error.t()]}
  def analyze(ast) do
    # TODO: Implement analyzer
    {:ok, ast}
  end
end
ELIXIR

cat > apps/skein_compiler/lib/skein/codegen/core_erlang.ex << 'ELIXIR'
defmodule Skein.CodeGen.CoreErlang do
  @moduledoc """
  Code generator: Skein AST -> Core Erlang -> BEAM bytecode.

  Uses the :cerl module to build Core Erlang AST nodes programmatically,
  then calls :compile.forms/2 to produce .beam bytecode.
  """

  @spec generate(Skein.AST.Module.t()) :: {:ok, binary()} | {:error, [Skein.Error.t()]}
  def generate(ast) do
    # TODO: Implement code generation
    {:error, [%Skein.Error{
      code: "E0001",
      severity: :error,
      message: "Code generator not yet implemented",
      location: %{file: "unknown", line: 1, col: 1}
    }]}
  end
end
ELIXIR

cat > apps/skein_compiler/lib/skein/codegen/schema_gen.ex << 'ELIXIR'
defmodule Skein.CodeGen.SchemaGen do
  @moduledoc """
  Generates JSON Schemas from Skein type declarations.

  Used for:
  - LLM tool calling manifests
  - HTTP request/response validation
  - LLM constrained decoding (llm.json[T])
  """

  @spec to_json_schema(Skein.AST.TypeDecl.t()) :: map()
  def to_json_schema(%Skein.AST.TypeDecl{} = type_decl) do
    # TODO: Implement schema generation
    %{}
  end
end
ELIXIR

# Create first test file
cat > apps/skein_compiler/test/skein/lexer_test.exs << 'ELIXIR'
defmodule Skein.LexerTest do
  use ExUnit.Case, async: true

  alias Skein.Lexer

  describe "tokenize/1" do
    test "tokenizes a simple let binding" do
      assert {:ok, tokens} = Lexer.tokenize("let x = 42")

      assert tokens == [
        {:let, {1, 1}},
        {:ident, {1, 5}, "x"},
        {:eq, {1, 7}},
        {:int, {1, 9}, 42},
        {:eof, {1, 11}}
      ]
    end

    test "tokenizes a module declaration" do
      assert {:ok, tokens} = Lexer.tokenize("module Hello { }")

      assert tokens == [
        {:module, {1, 1}},
        {:upper_ident, {1, 8}, "Hello"},
        {:lbrace, {1, 14}},
        {:rbrace, {1, 16}},
        {:eof, {1, 17}}
      ]
    end

    test "tokenizes string with interpolation" do
      assert {:ok, tokens} = Lexer.tokenize(~s("Hello, ${name}!"))

      assert tokens == [
        {:string, {1, 1}, [
          {:literal, "Hello, "},
          {:interpolation, {:ident, {1, 11}, "name"}},
          {:literal, "!"}
        ]},
        {:eof, {1, 17}}
      ]
    end

    test "skips comments" do
      assert {:ok, tokens} = Lexer.tokenize("let x = 42 -- this is a comment")

      assert tokens == [
        {:let, {1, 1}},
        {:ident, {1, 5}, "x"},
        {:eq, {1, 7}},
        {:int, {1, 9}, 42},
        {:eof, {1, 32}}
      ]
    end

    test "tokenizes function declaration" do
      source = """
      fn greet(name: String) -> String {
        "Hello, ${name}!"
      }
      """

      assert {:ok, tokens} = Lexer.tokenize(source)
      assert {:fn, {1, 1}} == hd(tokens)
    end

    test "tokenizes all operators" do
      assert {:ok, tokens} = Lexer.tokenize("= -> |> ! ? . : , @ &")
      types = Enum.map(tokens, &elem(&1, 0))
      assert :eq in types
      assert :arrow in types
      assert :pipe in types
      assert :bang in types
      assert :question in types
    end

    test "reports error on unterminated string" do
      assert {:error, [error]} = Lexer.tokenize(~s("unterminated))
      assert error.code == "E0002"
    end
  end
end
ELIXIR

cat > apps/skein_compiler/test/skein/parser_test.exs << 'ELIXIR'
defmodule Skein.ParserTest do
  use ExUnit.Case, async: true

  alias Skein.Parser
  alias Skein.Lexer
  alias Skein.AST

  defp parse(source) do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      Parser.parse(tokens)
    end
  end

  describe "parse/1" do
    test "parses an empty module" do
      assert {:ok, %AST.Module{name: "Hello", declarations: []}} = parse("module Hello { }")
    end

    test "parses a module with a function" do
      source = """
      module Hello {
        fn greet(name: String) -> String {
          "Hello, ${name}!"
        }
      }
      """

      assert {:ok, %AST.Module{name: "Hello", declarations: [fn_decl]}} = parse(source)
      assert %AST.Fn{name: "greet"} = fn_decl
    end

    test "parses let bindings" do
      source = """
      module Math {
        fn add(a: Int, b: Int) -> Int {
          let result = a + b
          result
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [%AST.Fn{body: body}]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Let{name: "result"}, _]} = body
    end

    test "parses match expressions" do
      source = """
      module Logic {
        fn classify(n: Int) -> String {
          match n > 0 {
            true  -> "positive"
            false -> "non-positive"
          }
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [%AST.Fn{body: body}]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Match{arms: [_, _]}]} = body
    end

    test "parses pipe expressions" do
      source = """
      module Transform {
        fn process(data: String) -> String {
          data |> String.trim() |> String.upcase()
        }
      }
      """

      assert {:ok, %AST.Module{declarations: [%AST.Fn{body: body}]}} = parse(source)
      assert %AST.Block{expressions: [%AST.Pipe{}]} = body
    end
  end
end
ELIXIR

# Create .gitignore
cat > .gitignore << 'GITIGNORE'
# Elixir/Mix
/_build/
/deps/
*.ez
*.beam

# Generated
/cover/
/doc/

# Editor
.elixir_ls/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Crash dumps
erl_crash.dump

# Skein build output
/_release/
GITIGNORE

# Create config
mkdir -p config
cat > config/config.exs << 'ELIXIR'
import Config

# Shared configuration for all environments
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
ELIXIR

# Initialize git
echo "  Initializing git repository..."
git init
git add .
git commit -m "[phase-0] Initial project scaffolding

- Umbrella project with skein_compiler, skein_runtime, skein_cli apps
- AST node definitions
- Structured error types
- Stub lexer, parser, analyzer, code generator
- Phase 1 test stubs for lexer and parser
- Example .skein files
- Project documentation (CLAUDE.md, SKEIN_SPEC.md, ARCHITECTURE.md, IMPLEMENTATION_PLAN.md)"

echo ""
echo "✅ Skein project bootstrapped successfully!"
echo ""
echo "Next steps:"
echo "  cd skein"
echo "  mix deps.get"
echo "  mix test"
echo ""
echo "Start Phase 1 by implementing Skein.Lexer (apps/skein_compiler/lib/skein/lexer.ex)"
echo "Run tests with: mix test apps/skein_compiler/test/skein/lexer_test.exs"
