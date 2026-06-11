defmodule Skein.Lsp.CodeActions do
  @moduledoc """
  Quickfix code actions derived from the `fix_hint`/`fix_code` that every
  `Skein.Error` carries.

  Phase 1 of issue #108: a per-code edit mapping for the mechanical wins.
  The handler answers from the diagnostic's `data` payload alone (shipped
  by `Skein.Lsp.Diagnostics`) plus the document source — no recompile.

  Mapped codes:

    * `E0001` missing-token errors — `fix_code` is the literal token,
      inserted immediately after the keyword the message names
    * `E0012` missing capability — `fix_code` is the full declaration
      line, inserted after the last existing `capability` line (or the
      module/agent opening line)
    * `W0002` unused capability — the declaration's line is deleted
    * `W0001` unused binding — the binding name is replaced with the
      underscore-prefixed `fix_code`

  Diagnostics whose code has no mapping produce no action.
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

    case build_edits(code, fix_code, message, line, character, source) do
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
