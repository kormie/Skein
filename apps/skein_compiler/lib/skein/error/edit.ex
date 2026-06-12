defmodule Skein.Error.Edit do
  @moduledoc """
  Reference implementation for applying a machine-applicable fix
  (`span` + `edit_kind` + `fix_code`) to source text.

  This is the canonical semantics of `Skein.Error.edit_kind/0`; the LSP
  builds editor `TextEdit`s with the same meaning, and agents consuming
  `skein mcp` compile_check output can apply fixes the same way.
  """

  alias Skein.Error

  @doc """
  Applies the error's fix to `source`.

  Returns `{:ok, new_source}`, or `:not_applicable` when the error
  carries no machine-applicable edit (no `edit_kind`, no usable span, or
  a missing `fix_code` for a kind that inserts or replaces text).
  """
  @spec apply_fix(String.t(), Error.t()) :: {:ok, String.t()} | :not_applicable
  def apply_fix(source, %Error{edit_kind: kind, span: span} = error)
      when not is_nil(kind) and is_map(span) do
    lines = String.split(source, "\n")

    case edit(lines, kind, span, error.fix_code) do
      {:ok, new_lines} -> {:ok, Enum.join(new_lines, "\n")}
      :error -> :not_applicable
    end
  end

  def apply_fix(_source, %Error{}), do: :not_applicable

  defp edit(lines, :replace, span, fix_code) when is_binary(fix_code) do
    replace_range(lines, span, fix_code)
  end

  defp edit(lines, :insert_before, %{start: start}, fix_code) when is_binary(fix_code) do
    insert_at(lines, start, fix_code)
  end

  defp edit(lines, :insert_after, %{end: stop}, fix_code) when is_binary(fix_code) do
    insert_at(lines, stop, fix_code)
  end

  defp edit(lines, :insert_line, %{start: %{line: line, col: col}}, fix_code)
       when is_binary(fix_code) do
    if line >= 1 and line <= length(lines) + 1 do
      new_line = String.duplicate(" ", max(col - 1, 0)) <> fix_code
      {:ok, List.insert_at(lines, line - 1, new_line)}
    else
      :error
    end
  end

  defp edit(lines, :delete_line, %{start: %{line: first}, end: %{line: last}}, _fix_code) do
    if first >= 1 and last >= first and first <= length(lines) do
      {kept, _} =
        lines
        |> Enum.with_index(1)
        |> Enum.split_with(fn {_text, index} -> index < first or index > last end)

      {:ok, Enum.map(kept, &elem(&1, 0))}
    else
      :error
    end
  end

  defp edit(_lines, _kind, _span, _fix_code), do: :error

  # Single-line replacement only: every replace-kind error the compiler
  # emits spans one line (identifiers, literals, single tokens).
  defp replace_range(lines, %{start: %{line: line, col: from}, end: %{line: line, col: to}}, text)
       when from >= 1 and to >= from do
    with line_text when is_binary(line_text) <- Enum.at(lines, line - 1),
         true <- to - 1 <= String.length(line_text) do
      head = String.slice(line_text, 0, from - 1)
      tail = String.slice(line_text, (to - 1)..-1//1) || ""
      {:ok, List.replace_at(lines, line - 1, head <> text <> tail)}
    else
      _ -> :error
    end
  end

  defp replace_range(_lines, _span, _text), do: :error

  defp insert_at(lines, %{line: line, col: col}, text) when line >= 1 and col >= 1 do
    case Enum.at(lines, line - 1) do
      nil ->
        :error

      line_text ->
        position = min(col - 1, String.length(line_text))
        head = String.slice(line_text, 0, position)
        tail = String.slice(line_text, position..-1//1) || ""
        {:ok, List.replace_at(lines, line - 1, head <> text <> tail)}
    end
  end

  defp insert_at(_lines, _position, _text), do: :error
end
