defmodule Skein.Lsp.CodeActions do
  @moduledoc """
  Quickfix code actions derived from the structured fix data every
  `Skein.Error` carries.

  Phase 2 of the code-actions plan (issue #150): errors that ship a
  `span` + `edit_kind` (the machine-applicable discriminator on
  `Skein.Error`) are applied generically — no per-error-code logic.
  The edit kinds mirror `Skein.Error.Edit`:

    * `replace` — replace the spanned text with `fix_code`
    * `insert_before` / `insert_after` — insert `fix_code` at the span's
      start / end
    * `insert_line` — insert `fix_code` as a new line at the span's
      start line, indented to the span's start column
    * `delete_line` — delete the line(s) the span covers

  Diagnostics without span data fall back to the phase-1 per-code
  mapping (issue #108): E0001 missing-token, E0012 missing capability,
  W0002 unused capability, and W0001 unused binding. The handler answers
  from the diagnostic's `data` payload alone (shipped by
  `Skein.Lsp.Diagnostics`) plus the document source — no recompile.

  Diagnostics with neither produce no action.
  """

  alias GenLSP.Structures.{CodeAction, Position, Range, TextEdit, WorkspaceEdit}

  @doc """
  Builds quickfix actions for the diagnostics that have an applicable fix.

  Accepts `GenLSP.Structures.Diagnostic` structs (server-side) or the
  string-keyed maps a client sends back in `codeAction` context.
  """
  @spec actions(String.t(), String.t(), [GenLSP.Structures.Diagnostic.t() | map()]) ::
          [CodeAction.t()]
  def actions(uri, source, diagnostics) do
    Enum.flat_map(diagnostics, fn diagnostic ->
      case build_action(uri, source, diagnostic) do
        nil -> []
        action -> [action]
      end
    end)
  end

  defp build_action(uri, source, diagnostic) do
    data = field(diagnostic, :data) || %{}
    code = Map.get(data, "code") || field(diagnostic, :code)
    fix_code = Map.get(data, "fix_code")
    fix_hint = Map.get(data, "fix_hint")
    message = field(diagnostic, :message) || ""

    start = field(field(diagnostic, :range), :start)
    line = field(start, :line) || 0
    character = field(start, :character) || 0

    edits =
      generic_edits(Map.get(data, "edit_kind"), Map.get(data, "span"), fix_code) ||
        build_edits(code, fix_code, message, line, character, source)

    case edits do
      nil ->
        nil

      edits ->
        %CodeAction{
          title: fix_hint || "Apply Skein fix",
          kind: "quickfix",
          diagnostics: [diagnostic],
          edit: %WorkspaceEdit{changes: %{uri => edits}}
        }
    end
  end

  # ------------------------------------------------------------------
  # Generic span + edit_kind application (phase 2)
  # ------------------------------------------------------------------

  defp generic_edits(kind, span, fix_code) when is_binary(kind) and is_map(span) do
    with %Position{} = start <- span_position(span, :start),
         %Position{} = stop <- span_position(span, :end) do
      build_generic_edit(kind, start, stop, fix_code)
    else
      _ -> nil
    end
  end

  defp generic_edits(_kind, _span, _fix_code), do: nil

  defp build_generic_edit("replace", start, stop, fix_code) when is_binary(fix_code) do
    [%TextEdit{range: %Range{start: start, end: stop}, new_text: fix_code}]
  end

  defp build_generic_edit("insert_before", start, _stop, fix_code) when is_binary(fix_code) do
    [%TextEdit{range: %Range{start: start, end: start}, new_text: fix_code}]
  end

  defp build_generic_edit("insert_after", _start, stop, fix_code) when is_binary(fix_code) do
    [%TextEdit{range: %Range{start: stop, end: stop}, new_text: fix_code}]
  end

  defp build_generic_edit("insert_line", start, _stop, fix_code) when is_binary(fix_code) do
    position = %Position{line: start.line, character: 0}
    indent = String.duplicate(" ", start.character)

    [
      %TextEdit{
        range: %Range{start: position, end: position},
        new_text: indent <> fix_code <> "\n"
      }
    ]
  end

  defp build_generic_edit("delete_line", start, stop, _fix_code) do
    [
      %TextEdit{
        range: %Range{
          start: %Position{line: start.line, character: 0},
          end: %Position{line: stop.line + 1, character: 0}
        },
        new_text: ""
      }
    ]
  end

  defp build_generic_edit(_kind, _start, _stop, _fix_code), do: nil

  # Span positions are 1-based {line, col} maps (string keys after the
  # JSON round-trip); LSP positions are 0-based.
  defp span_position(span, key) do
    case field(span, key) do
      %{} = position ->
        line = field(position, :line)
        col = field(position, :col)

        if is_integer(line) and line > 0 and is_integer(col) and col > 0 do
          %Position{line: line - 1, character: col - 1}
        end

      _ ->
        nil
    end
  end

  # Missing token: the diagnostic sits on the keyword the message names;
  # the token inserts immediately after it.
  defp build_edits("E0001", fix_code, message, line, character, _source)
       when is_binary(fix_code) and fix_code != "" do
    case Regex.run(~r/Missing '.+' after '(.+)'/, message) do
      [_, keyword] ->
        position = %Position{line: line, character: character + String.length(keyword)}
        [%TextEdit{range: %Range{start: position, end: position}, new_text: fix_code}]

      _ ->
        nil
    end
  end

  # Missing capability: insert the declaration line after the last
  # existing capability, or after the module/agent opening line.
  defp build_edits("E0012", "capability " <> _ = fix_code, _message, _line, _character, source) do
    lines = String.split(source, "\n")

    capability_index = last_index(lines, &Regex.match?(~r/^\s*capability\b/, &1))
    opening_index = Enum.find_index(lines, &Regex.match?(~r/^\s*(module|agent)\b.*\{/, &1))

    case capability_index || opening_index do
      nil ->
        nil

      index ->
        reference_line = Enum.at(lines, index)

        indent =
          if capability_index,
            do: line_indent(reference_line),
            else: line_indent(reference_line) <> "  "

        position = %Position{line: index + 1, character: 0}

        [
          %TextEdit{
            range: %Range{start: position, end: position},
            new_text: indent <> fix_code <> "\n"
          }
        ]
    end
  end

  # Unused capability: delete the declaration's whole line.
  defp build_edits("W0002", _fix_code, _message, line, _character, _source) do
    [
      %TextEdit{
        range: %Range{
          start: %Position{line: line, character: 0},
          end: %Position{line: line + 1, character: 0}
        },
        new_text: ""
      }
    ]
  end

  # Unused binding: replace the name on the diagnostic's line with the
  # underscore-prefixed fix_code.
  defp build_edits("W0001", "_" <> _ = fix_code, message, line, _character, source) do
    with [_, name] <- Regex.run(~r/Unused binding '([^']+)'/, message),
         line_text when is_binary(line_text) <- Enum.at(String.split(source, "\n"), line),
         [{start_col, length}] <-
           Regex.run(~r/\b#{Regex.escape(name)}\b/, line_text, return: :index) do
      [
        %TextEdit{
          range: %Range{
            start: %Position{line: line, character: start_col},
            end: %Position{line: line, character: start_col + length}
          },
          new_text: fix_code
        }
      ]
    else
      _ -> nil
    end
  end

  defp build_edits(_code, _fix_code, _message, _line, _character, _source), do: nil

  # Reads a field from a GenLSP struct or a string-keyed map from the wire.
  defp field(nil, _key), do: nil
  defp field(%_{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp last_index(lines, predicate) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {line, index}, acc ->
      if predicate.(line), do: index, else: acc
    end)
  end

  defp line_indent(line) do
    [indent] = Regex.run(~r/^[ \t]*/, line)
    indent
  end
end
