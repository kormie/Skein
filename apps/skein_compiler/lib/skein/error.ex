defmodule Skein.Error do
  @moduledoc """
  Structured compiler error.

  All errors are JSON-serializable and include machine-readable fix hints
  for LLM-driven code correction loops.

  ## Machine-applicable fixes

  Errors that carry an *exact* `fix_code` also carry a `span` and an
  `edit_kind`, so any consumer (LSP, MCP, agents) can apply the fix
  generically without per-error-code logic:

    * `:replace` — replace the source text covered by `span` with
      `fix_code` (an empty `fix_code` deletes the spanned text)
    * `:insert_before` — insert `fix_code` immediately before `span.start`
    * `:insert_after` — insert `fix_code` immediately after `span.end`
    * `:insert_line` — insert `fix_code` as a new line at `span.start.line`
      (pushing that line down), indented to column `span.start.col`
    * `:delete_line` — delete the whole line(s) from `span.start.line`
      to `span.end.line`

  A `nil` `edit_kind` means the error's `fix_code` (if any) is an
  illustrative template (e.g. `"fn name() -> Type { ... }"`), not an
  edit to apply verbatim.

  Spans are 1-based like `location`; `end.col` is exclusive (a span
  covering the word `abc` at column 5 ends at column 8). A zero-width
  span (`start == end`) marks a pure insertion point.
  """

  @derive Jason.Encoder
  defstruct [
    :code,
    :severity,
    :message,
    :location,
    :context,
    :fix_hint,
    :fix_code,
    :span,
    :edit_kind
  ]

  @type position :: %{line: pos_integer(), col: pos_integer()}
  @type span :: %{start: position(), end: position()}
  @type edit_kind :: :replace | :insert_before | :insert_after | :insert_line | :delete_line

  @type t :: %__MODULE__{
          code: String.t(),
          severity: :error | :warning,
          message: String.t(),
          location: %{file: String.t(), line: pos_integer(), col: pos_integer()},
          context: String.t() | nil,
          fix_hint: String.t() | nil,
          fix_code: String.t() | nil,
          span: span() | nil,
          edit_kind: edit_kind() | nil
        }

  @edit_kinds [:replace, :insert_before, :insert_after, :insert_line, :delete_line]

  @doc "The edit kinds a machine-applicable error may carry."
  @spec edit_kinds() :: [edit_kind()]
  def edit_kinds, do: @edit_kinds

  @doc """
  Builds a single-line span starting at `{line, col}` and covering
  `length` columns (0 for a pure insertion point).
  """
  @spec span(pos_integer(), pos_integer(), non_neg_integer()) :: span()
  def span(line, col, length)
      when is_integer(line) and is_integer(col) and is_integer(length) and length >= 0 do
    %{start: %{line: line, col: col}, end: %{line: line, col: col + length}}
  end

  @doc "Builds a zero-width span marking an insertion point."
  @spec point(pos_integer(), pos_integer()) :: span()
  def point(line, col), do: span(line, col, 0)

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    Jason.encode!(error)
  end

  @spec to_json_list([t()]) :: String.t()
  def to_json_list(errors) when is_list(errors) do
    Jason.encode!(%{errors: errors})
  end
end
