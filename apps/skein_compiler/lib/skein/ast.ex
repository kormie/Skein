defmodule Skein.AST do
  @moduledoc """
  AST node definitions for Skein.

  Every node carries a `meta` field with source location:
  %{line: integer, col: integer, file: string}
  """

  @typedoc "Source location metadata attached to every AST node."
  @type meta :: %{line: pos_integer(), col: pos_integer(), file: String.t()}

  @typedoc "Any AST expression node."
  @type expr :: term()

  # Top-level declarations

  defmodule Module do
    @moduledoc "A Skein module declaration."

    @type t :: %__MODULE__{
            name: String.t(),
            capabilities: [Skein.AST.Capability.t()],
            declarations: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :capabilities, :declarations, :meta]
  end

  defmodule Capability do
    @moduledoc """
    A capability declaration.

    In a module or agent body a capability is a flat declaration (`kind` +
    `params`). Inside a `scenario` it may also open a nested envelope: `nested`
    holds the capabilities scoped under it, and `implement` holds an optional
    test-only provider block (see `CapabilityImplement`). For production
    declarations `nested` is `[]` and `implement` is `nil`.
    """

    @type t :: %__MODULE__{
            kind: String.t(),
            params: [map()],
            nested: [Skein.AST.Capability.t()],
            implement: Skein.AST.CapabilityImplement.t() | nil,
            meta: Skein.AST.meta()
          }

    defstruct [:kind, :params, :nested, :implement, :meta]
  end

  defmodule CapabilityImplement do
    @moduledoc """
    A test-only effect provider block inside a scenario capability envelope:
    `implement(params) -> return_type { body }`. The body is local, typed, and
    pure (no effect calls) — enforced by the analyzer. Reuses the `implement`
    keyword that tool bodies already use.
    """

    @type t :: %__MODULE__{
            params: [Skein.AST.Field.t()],
            return_type: Skein.AST.TypeRef.t(),
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:params, :return_type, :body, :meta]
  end

  defmodule Fn do
    @moduledoc "A function declaration."

    @type t :: %__MODULE__{
            name: String.t(),
            params: [Skein.AST.Field.t()],
            return_type: Skein.AST.TypeRef.t() | nil,
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :params, :return_type, :body, :meta]
  end

  defmodule TypeDecl do
    @moduledoc "A named type declaration with fields and optional constraints."

    @type t :: %__MODULE__{
            name: String.t(),
            fields: [Skein.AST.Field.t()],
            constraints: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :fields, :constraints, :meta]
  end

  defmodule EnumDecl do
    @moduledoc "An enum declaration with variants and optional transitions."

    @type t :: %__MODULE__{
            name: String.t(),
            variants: [Skein.AST.Variant.t()],
            transitions: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :variants, :transitions, :meta]
  end

  defmodule Handler do
    @moduledoc "An HTTP, queue, schedule, or topic handler."

    @type t :: %__MODULE__{
            source: String.t(),
            method: String.t() | nil,
            route: String.t() | nil,
            param: Skein.AST.Field.t() | nil,
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:source, :method, :route, :param, :body, :meta]
  end

  defmodule Agent do
    @moduledoc "An agent declaration with state, phases, handlers, and functions."

    @type t :: %__MODULE__{
            name: String.t(),
            capabilities: [Skein.AST.Capability.t()],
            state: [Skein.AST.Field.t()],
            phases: Skein.AST.EnumDecl.t() | nil,
            handlers: [Skein.AST.AgentHandler.t()],
            fns: [Skein.AST.Fn.t()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :capabilities, :state, :phases, :handlers, :fns, :meta]
  end

  defmodule AgentHandler do
    @moduledoc "A handler within an agent (on start, on phase, on message)."

    @type t :: %__MODULE__{
            kind: atom(),
            phase: String.t() | nil,
            params: [Skein.AST.Field.t()],
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:kind, :phase, :params, :body, :meta]
  end

  defmodule ToolDecl do
    @moduledoc "A tool declaration with input/output schemas and errors."

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            input: [Skein.AST.Field.t()],
            output: [Skein.AST.Field.t()],
            errors: [term()],
            implement: Skein.AST.expr() | nil,
            meta: Skein.AST.meta()
          }

    defstruct [:name, :description, :input, :output, :errors, :implement, :meta]
  end

  defmodule Supervisor do
    @moduledoc "A supervisor declaration with children and restart strategy."

    @type t :: %__MODULE__{
            name: String.t(),
            children: [Skein.AST.Child.t()],
            strategy: atom() | nil,
            max_restarts: {pos_integer(), pos_integer()} | nil,
            meta: Skein.AST.meta()
          }

    defstruct [:name, :children, :strategy, :max_restarts, :meta]
  end

  defmodule Child do
    @moduledoc "A child specification within a supervisor."

    @type t :: %__MODULE__{
            target: Skein.AST.expr(),
            args: [term()],
            options: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:target, :args, :options, :meta]
  end

  defmodule Test do
    @moduledoc "A test declaration with a description and body."

    @type t :: %__MODULE__{
            description: String.t(),
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:description, :body, :meta]
  end

  defmodule Scenario do
    @moduledoc """
    A scenario test. Carries an optional nested capability environment
    (`capabilities` — the tool-scoped envelopes with `implement` providers),
    `given` seed bindings, and an `expect` block of assertions.
    """

    @type t :: %__MODULE__{
            description: String.t(),
            capabilities: [Skein.AST.Capability.t()],
            given_vars: [term()],
            expect_body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:description, :capabilities, :given_vars, :expect_body, :meta]
  end

  defmodule Golden do
    @moduledoc "A golden test with optional trace file."

    @type t :: %__MODULE__{
            description: String.t(),
            trace_file: String.t() | nil,
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:description, :trace_file, :body, :meta]
  end

  # Type nodes

  defmodule TypeRef do
    @moduledoc "A reference to a type, with optional type parameters."

    @type t :: %__MODULE__{
            name: String.t(),
            params: [t()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :params, :meta]
  end

  defmodule Field do
    @moduledoc "A named field with a type and optional annotations."

    @type t :: %__MODULE__{
            name: String.t(),
            type: Skein.AST.TypeRef.t(),
            annotations: [Skein.AST.Annotation.t()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :type, :annotations, :meta]
  end

  defmodule Variant do
    @moduledoc "A variant within an enum declaration."

    @type t :: %__MODULE__{
            name: String.t(),
            fields: [Skein.AST.Field.t()],
            transitions: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:name, :fields, :transitions, :meta]
  end

  defmodule Annotation do
    @moduledoc "A constraint annotation on a field (e.g., `@min`, `@max`, `@format`)."

    @type t :: %__MODULE__{
            name: String.t(),
            value: term(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :value, :meta]
  end

  # Expression nodes

  defmodule Let do
    @moduledoc "A let binding expression."

    @type t :: %__MODULE__{
            name: String.t(),
            type: Skein.AST.TypeRef.t() | nil,
            value: Skein.AST.expr(),
            meta: Skein.AST.meta(),
            name_meta: Skein.AST.meta() | nil
          }

    # name_meta locates the binding name itself (meta points at `let`),
    # so diagnostics can span the exact identifier.
    defstruct [:name, :type, :value, :meta, :name_meta]
  end

  defmodule Match do
    @moduledoc "A match expression with a subject and match arms."

    @type t :: %__MODULE__{
            subject: Skein.AST.expr(),
            arms: [Skein.AST.MatchArm.t()],
            meta: Skein.AST.meta()
          }

    defstruct [:subject, :arms, :meta]
  end

  defmodule MatchArm do
    @moduledoc "A single arm of a match expression."

    @type t :: %__MODULE__{
            pattern: Skein.AST.expr(),
            guard: Skein.AST.expr() | nil,
            body: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:pattern, :guard, :body, :meta]
  end

  defmodule Call do
    @moduledoc "A function or method call expression."

    @type t :: %__MODULE__{
            target: Skein.AST.expr(),
            args: [Skein.AST.expr()],
            type_param: Skein.AST.TypeRef.t() | nil,
            meta: Skein.AST.meta()
          }

    defstruct [:target, :args, :type_param, :meta]
  end

  defmodule NamedArg do
    @moduledoc """
    A named argument in a call: `name: value`.

    Only valid inside call argument lists, after any positional
    arguments. The analyzer validates names against the callee's
    parameter names and rewrites named arguments into positional
    order, so codegen only ever sees positional arguments.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            value: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :value, :meta]
  end

  defmodule Pipe do
    @moduledoc "A pipe expression (`|>`)."

    @type t :: %__MODULE__{
            left: Skein.AST.expr(),
            right: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:left, :right, :meta]
  end

  defmodule FieldAccess do
    @moduledoc "A field access expression (`subject.field`)."

    @type t :: %__MODULE__{
            subject: Skein.AST.expr(),
            field: String.t(),
            meta: Skein.AST.meta()
          }

    defstruct [:subject, :field, :meta]
  end

  defmodule BinaryOp do
    @moduledoc "A binary operator expression."

    @type t :: %__MODULE__{
            op: atom(),
            left: Skein.AST.expr(),
            right: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:op, :left, :right, :meta]
  end

  defmodule UnaryOp do
    @moduledoc "A unary operator expression."

    @type t :: %__MODULE__{
            op: atom(),
            operand: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:op, :operand, :meta]
  end

  defmodule StringLit do
    @moduledoc "A string literal, possibly with interpolation segments."

    @type t :: %__MODULE__{
            segments: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:segments, :meta]
  end

  defmodule IntLit do
    @moduledoc "An integer literal."

    @type t :: %__MODULE__{
            value: integer(),
            meta: Skein.AST.meta()
          }

    defstruct [:value, :meta]
  end

  defmodule FloatLit do
    @moduledoc "A floating-point literal."

    @type t :: %__MODULE__{
            value: float(),
            meta: Skein.AST.meta()
          }

    defstruct [:value, :meta]
  end

  defmodule BoolLit do
    @moduledoc "A boolean literal."

    @type t :: %__MODULE__{
            value: boolean(),
            meta: Skein.AST.meta()
          }

    defstruct [:value, :meta]
  end

  defmodule ListLit do
    @moduledoc "A list literal."

    @type t :: %__MODULE__{
            elements: [Skein.AST.expr()],
            meta: Skein.AST.meta()
          }

    defstruct [:elements, :meta]
  end

  defmodule MapLit do
    @moduledoc "A map literal."

    @type t :: %__MODULE__{
            entries: [{String.t(), Skein.AST.expr()}],
            meta: Skein.AST.meta()
          }

    defstruct [:entries, :meta]
  end

  defmodule RecordLit do
    @moduledoc """
    A nominal record literal: `TypeName { field: expr, ... }`. Constructs a
    value of a named `type`. Lowers to an atom-keyed map (the runtime
    representation all user-type values share); the type name is checked by the
    analyzer against the type's declared fields.
    """

    @type t :: %__MODULE__{
            type_name: String.t(),
            fields: [{String.t(), Skein.AST.expr()}],
            some_fields: [String.t()] | nil,
            none_fields: [String.t()] | nil,
            meta: Skein.AST.meta()
          }

    # `some_fields`/`none_fields` are the analyzer's Option-field plan (#294):
    # present Option-declared fields (codegen wraps their value in Some) and
    # absent ones (codegen injects None so constructed records are total).
    # The parser leaves them nil; the analyzer's annotation pass fills them.
    defstruct [:type_name, :fields, :some_fields, :none_fields, :meta]
  end

  defmodule Block do
    @moduledoc "A block of expressions."

    @type t :: %__MODULE__{
            expressions: [Skein.AST.expr()],
            meta: Skein.AST.meta()
          }

    defstruct [:expressions, :meta]
  end

  defmodule Identifier do
    @moduledoc "An identifier reference."

    @type t :: %__MODULE__{
            name: String.t(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :meta]
  end

  defmodule ToolRef do
    @moduledoc "A reference to a declared tool."

    @type t :: %__MODULE__{
            name: String.t(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :meta]
  end

  defmodule FnRef do
    @moduledoc "A reference to a function (`&fn_name`)."

    @type t :: %__MODULE__{
            name: String.t(),
            meta: Skein.AST.meta()
          }

    defstruct [:name, :meta]
  end

  defmodule Transition do
    @moduledoc "A phase transition expression within an agent."

    @type t :: %__MODULE__{
            phase: String.t(),
            meta: Skein.AST.meta()
          }

    defstruct [:phase, :meta]
  end

  defmodule Stop do
    @moduledoc "A stop expression that terminates an agent."

    @type t :: %__MODULE__{
            meta: Skein.AST.meta()
          }

    defstruct [:meta]
  end

  defmodule Suspend do
    @moduledoc "A suspend expression that pauses an agent with a reason."

    @type t :: %__MODULE__{
            reason: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:reason, :meta]
  end

  defmodule Idempotent do
    @moduledoc "An idempotent guard that prevents duplicate handler execution."

    @type t :: %__MODULE__{
            key: Skein.AST.expr(),
            meta: Skein.AST.meta()
          }

    defstruct [:key, :meta]
  end

  defmodule Emit do
    @moduledoc "An emit expression for publishing events."

    @type t :: %__MODULE__{
            event_name: String.t(),
            fields: [term()],
            meta: Skein.AST.meta()
          }

    defstruct [:event_name, :fields, :meta]
  end

  defmodule Respond do
    @moduledoc "A respond expression (json, text, or html)."

    @type t :: %__MODULE__{
            method: String.t(),
            args: [Skein.AST.expr()],
            meta: Skein.AST.meta()
          }

    defstruct [:method, :args, :meta]
  end

  defmodule Wildcard do
    @moduledoc "A wildcard pattern (`_`) in match expressions."

    @type t :: %__MODULE__{
            meta: Skein.AST.meta()
          }

    defstruct [:meta]
  end
end
