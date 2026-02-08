defmodule Skein.AST do
  @moduledoc """
  AST node definitions for Skein.

  Every node carries a `meta` field with source location:
  %{line: integer, col: integer, file: string}
  """

  # Top-level declarations
  defmodule Module, do: defstruct([:name, :capabilities, :declarations, :meta])
  defmodule Capability, do: defstruct([:kind, :params, :meta])
  defmodule Fn, do: defstruct([:name, :params, :return_type, :body, :meta])
  defmodule TypeDecl, do: defstruct([:name, :fields, :constraints, :meta])
  defmodule EnumDecl, do: defstruct([:name, :variants, :transitions, :meta])
  defmodule Handler, do: defstruct([:source, :method, :route, :param, :body, :meta])
  defmodule Agent, do: defstruct([:name, :capabilities, :state, :phases, :handlers, :fns, :meta])
  defmodule AgentHandler, do: defstruct([:kind, :phase, :params, :body, :meta])

  defmodule ToolDecl,
    do: defstruct([:name, :description, :input, :output, :errors, :policy, :implement, :meta])

  defmodule Supervisor, do: defstruct([:name, :children, :strategy, :max_restarts, :meta])
  defmodule Child, do: defstruct([:target, :args, :options, :meta])
  defmodule Test, do: defstruct([:description, :body, :meta])
  defmodule Scenario, do: defstruct([:description, :given_vars, :expect_body, :meta])
  defmodule Golden, do: defstruct([:description, :trace_file, :body, :meta])

  # Type nodes
  defmodule TypeRef, do: defstruct([:name, :params, :meta])
  defmodule Field, do: defstruct([:name, :type, :annotations, :meta])
  defmodule Variant, do: defstruct([:name, :fields, :transitions, :meta])
  defmodule Annotation, do: defstruct([:name, :value, :meta])

  # Expression nodes
  defmodule Let, do: defstruct([:name, :type, :value, :meta])
  defmodule Match, do: defstruct([:subject, :arms, :meta])
  defmodule MatchArm, do: defstruct([:pattern, :guard, :body, :meta])
  defmodule Call, do: defstruct([:target, :args, :type_param, :meta])
  defmodule Pipe, do: defstruct([:left, :right, :meta])
  defmodule FieldAccess, do: defstruct([:subject, :field, :meta])
  defmodule BinaryOp, do: defstruct([:op, :left, :right, :meta])
  defmodule UnaryOp, do: defstruct([:op, :operand, :meta])
  defmodule StringLit, do: defstruct([:segments, :meta])
  defmodule IntLit, do: defstruct([:value, :meta])
  defmodule FloatLit, do: defstruct([:value, :meta])
  defmodule BoolLit, do: defstruct([:value, :meta])
  defmodule ListLit, do: defstruct([:elements, :meta])
  defmodule MapLit, do: defstruct([:entries, :meta])
  defmodule Block, do: defstruct([:expressions, :meta])
  defmodule Identifier, do: defstruct([:name, :meta])
  defmodule ToolRef, do: defstruct([:name, :meta])
  defmodule FnRef, do: defstruct([:name, :meta])
  defmodule Transition, do: defstruct([:phase, :meta])
  defmodule Stop, do: defstruct([:meta])
  defmodule Emit, do: defstruct([:event_name, :fields, :meta])
  defmodule Respond, do: defstruct([:method, :args, :meta])
  defmodule Wildcard, do: defstruct([:meta])
end
