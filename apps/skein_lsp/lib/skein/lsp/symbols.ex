defmodule Skein.Lsp.Symbols do
  @moduledoc """
  Extracts document symbols from the Skein AST for the document outline.
  """

  alias GenLSP.Enumerations.SymbolKind

  alias GenLSP.Structures.{
    DocumentSymbol,
    Position,
    Range
  }

  @doc """
  Returns a list of `DocumentSymbol` for the given AST node.
  """
  @spec document_symbols(any()) :: [DocumentSymbol.t()]
  def document_symbols(%{__struct__: Skein.AST.Module} = mod) do
    children =
      extract_module_children(mod.declarations || [])

    [
      %DocumentSymbol{
        name: mod.name,
        kind: SymbolKind.module(),
        range: node_range(mod.meta),
        selection_range: node_range(mod.meta),
        children: children
      }
    ]
  end

  def document_symbols(%{__struct__: Skein.AST.Agent} = agent) do
    children =
      agent_children(agent)

    [
      %DocumentSymbol{
        name: agent.name,
        kind: SymbolKind.class(),
        range: node_range(agent.meta),
        selection_range: node_range(agent.meta),
        children: children
      }
    ]
  end

  def document_symbols(_), do: []

  # -- Module children --

  defp extract_module_children(declarations) do
    Enum.flat_map(declarations, fn
      %{__struct__: Skein.AST.Fn} = f ->
        [fn_symbol(f)]

      %{__struct__: Skein.AST.TypeDecl} = t ->
        [type_symbol(t)]

      %{__struct__: Skein.AST.EnumDecl} = e ->
        [enum_symbol(e)]

      %{__struct__: Skein.AST.Handler} = h ->
        [handler_symbol(h)]

      %{__struct__: Skein.AST.ToolDecl} = t ->
        [tool_symbol(t)]

      %{__struct__: Skein.AST.Supervisor} = s ->
        [supervisor_symbol(s)]

      %{__struct__: Skein.AST.Test} = t ->
        [test_symbol(t)]

      %{__struct__: Skein.AST.Scenario} = s ->
        [scenario_symbol(s)]

      %{__struct__: Skein.AST.Golden} = g ->
        [golden_symbol(g)]

      _ ->
        []
    end)
  end

  # -- Agent children --

  defp agent_children(agent) do
    state_symbols =
      case agent.state do
        fields when is_list(fields) and fields != [] ->
          state_field_symbols(fields, agent.meta)

        _ ->
          []
      end

    phase_symbols =
      case agent.phases do
        %{__struct__: Skein.AST.EnumDecl} = e -> [enum_symbol(e)]
        _ -> []
      end

    handler_symbols =
      (agent.handlers || [])
      |> Enum.map(&agent_handler_symbol/1)

    fn_symbols =
      (agent.fns || [])
      |> Enum.map(&fn_symbol/1)

    state_symbols ++ phase_symbols ++ handler_symbols ++ fn_symbols
  end

  # -- Individual symbol builders --

  defp fn_symbol(f) do
    params =
      (f.params || [])
      |> Enum.map(fn
        %{name: name, type: type} -> "#{name}: #{format_type(type)}"
        %{name: name} -> name
        _ -> "?"
      end)
      |> Enum.join(", ")

    detail =
      case f.return_type do
        nil -> nil
        type -> "-> #{format_type(type)}"
      end

    %DocumentSymbol{
      name: "fn #{f.name}(#{params})",
      detail: detail,
      kind: SymbolKind.function(),
      range: node_range(f.meta),
      selection_range: node_range(f.meta)
    }
  end

  defp type_symbol(t) do
    field_count = length(t.fields || [])

    %DocumentSymbol{
      name: t.name,
      detail: "#{field_count} fields",
      kind: SymbolKind.struct(),
      range: node_range(t.meta),
      selection_range: node_range(t.meta),
      children: Enum.map(t.fields || [], &field_symbol/1)
    }
  end

  defp enum_symbol(e) do
    variants =
      (e.variants || [])
      |> Enum.map(fn
        %{name: name} -> variant_symbol(name, e.meta)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %DocumentSymbol{
      name: e.name,
      kind: SymbolKind.enum(),
      range: node_range(e.meta),
      selection_range: node_range(e.meta),
      children: variants
    }
  end

  defp handler_symbol(h) do
    name = handler_display_name(h)

    %DocumentSymbol{
      name: name,
      kind: SymbolKind.event(),
      range: node_range(h.meta),
      selection_range: node_range(h.meta)
    }
  end

  defp agent_handler_symbol(h) do
    name =
      case h.kind do
        :start -> "on start"
        :phase -> "on phase(#{format_phase(h.phase)})"
        _ -> "on #{h.kind}"
      end

    %DocumentSymbol{
      name: name,
      kind: SymbolKind.event(),
      range: node_range(h.meta),
      selection_range: node_range(h.meta)
    }
  end

  defp tool_symbol(t) do
    %DocumentSymbol{
      name: "tool #{t.name}",
      kind: SymbolKind.interface(),
      range: node_range(t.meta),
      selection_range: node_range(t.meta)
    }
  end

  defp supervisor_symbol(s) do
    %DocumentSymbol{
      name: "supervisor #{s.name}",
      kind: SymbolKind.namespace(),
      range: node_range(s.meta),
      selection_range: node_range(s.meta)
    }
  end

  defp test_symbol(t) do
    %DocumentSymbol{
      name: "test #{t.description}",
      kind: SymbolKind.function(),
      range: node_range(t.meta),
      selection_range: node_range(t.meta)
    }
  end

  defp scenario_symbol(s) do
    %DocumentSymbol{
      name: "scenario #{s.description}",
      kind: SymbolKind.function(),
      range: node_range(s.meta),
      selection_range: node_range(s.meta)
    }
  end

  defp golden_symbol(g) do
    %DocumentSymbol{
      name: "golden #{g.description}",
      kind: SymbolKind.function(),
      range: node_range(g.meta),
      selection_range: node_range(g.meta)
    }
  end

  defp field_symbol(%{name: name, type: type} = field) do
    %DocumentSymbol{
      name: name,
      detail: format_type(type),
      kind: SymbolKind.field(),
      range: node_range(field.meta || %{line: 1, col: 1, file: ""}),
      selection_range: node_range(field.meta || %{line: 1, col: 1, file: ""})
    }
  end

  defp field_symbol(_), do: nil

  defp variant_symbol(name, meta) do
    %DocumentSymbol{
      name: name,
      kind: SymbolKind.enum_member(),
      range: node_range(meta),
      selection_range: node_range(meta)
    }
  end

  defp state_field_symbols(fields, parent_meta) do
    fields
    |> Enum.map(fn
      %{name: name, type: type, meta: meta} ->
        %DocumentSymbol{
          name: "state.#{name}",
          detail: format_type(type),
          kind: SymbolKind.property(),
          range: node_range(meta),
          selection_range: node_range(meta)
        }

      %{name: name, type: type} ->
        %DocumentSymbol{
          name: "state.#{name}",
          detail: format_type(type),
          kind: SymbolKind.property(),
          range: node_range(parent_meta),
          selection_range: node_range(parent_meta)
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # -- Formatting helpers --

  defp handler_display_name(%{source: :http, method: method, route: route}) do
    "handler http #{method} #{inspect(route)}"
  end

  defp handler_display_name(%{source: :queue, route: name}) do
    "handler queue #{inspect(name)}"
  end

  defp handler_display_name(%{source: :schedule, route: cron}) do
    "handler schedule #{inspect(cron)}"
  end

  defp handler_display_name(%{source: :topic, route: topic}) do
    "handler topic #{inspect(topic)}"
  end

  defp handler_display_name(h) do
    "handler #{inspect(h.source)}"
  end

  defp format_type(nil), do: ""
  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: []}), do: name

  defp format_type(%{__struct__: Skein.AST.TypeRef, name: name, params: params}) do
    inner = Enum.map_join(params, ", ", &format_type/1)
    "#{name}<#{inner}>"
  end

  defp format_type(name) when is_binary(name), do: name
  defp format_type(_), do: "?"

  defp format_phase(nil), do: "?"

  defp format_phase(%{__struct__: Skein.AST.FieldAccess, subject: subj, field: field}) do
    "#{format_phase(subj)}.#{field}"
  end

  defp format_phase(%{__struct__: Skein.AST.Identifier, name: name}), do: name
  defp format_phase(other) when is_binary(other), do: other
  defp format_phase(_), do: "?"

  defp node_range(meta) do
    line = max((meta[:line] || 1) - 1, 0)
    col = max((meta[:col] || 1) - 1, 0)

    %Range{
      start: %Position{line: line, character: col},
      end: %Position{line: line, character: col + 1}
    }
  end
end
